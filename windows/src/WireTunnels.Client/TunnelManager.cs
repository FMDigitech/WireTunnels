using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Storage;

namespace WireTunnels.Client;

public enum SetupState { Checking, ServiceMissing, ServiceStopped, ServiceStarting, Incompatible, Unreachable, Ready }

public sealed record TrafficSample(DateTimeOffset Time, double RxRate, double TxRate);

public sealed class ConfigValidationException(IEnumerable<string> errors)
    : Exception("Invalid WireGuard configuration: " + string.Join("; ", errors));

/// Port of TunnelManager.swift: owns the tunnel list, talks to the service, polls runtime status,
/// and runs connect / disconnect / quit with the same rules as macOS. Network parity (kill switch,
/// split DNS, exclusions, multi-hop, leaks) lives in TunnelManager.Network.cs.
/// Not thread-safe by design: call it from the UI thread only (awaits resume there).
public sealed partial class TunnelManager : ObservableObject, IShutdownClient
{
    public const int MaxTrafficSamples = 30;
    private static readonly TimeSpan PendingOperationsDeadline = TimeSpan.FromSeconds(90);

    private readonly ITunnelService _service;
    private readonly IServiceProbe _probe;
    private readonly ConfigStore _configs;
    private readonly RecoverableJsonStore<List<Tunnel>> _store;
    private readonly LogService _log;
    private readonly INotifier _notifier;
    private readonly Func<bool> _notificationsEnabled;
    private readonly TimeProvider _time;
    private readonly INetworkInfo _network;
    private readonly IInventoryRunner _inventory;
    private readonly RecoverableJsonStore<List<HopChain>>? _hopChainStore;
    private readonly Func<bool> _canAdminister;
    private readonly ConnectionFeedback _feedback = new();
    private readonly ShutdownCoordinator _shutdown = new();
    private readonly HashSet<Guid> _connecting = [];
    private readonly HashSet<Guid> _disconnecting = [];
    private readonly Dictionary<Guid, List<TrafficSample>> _traffic = [];
    private readonly Dictionary<Guid, (long Rx, long Tx, DateTimeOffset Time)> _trafficSnapshots = [];

    private List<Tunnel> _tunnels = [];
    private List<string> _unrecognizedRuntimeTunnels = [];
    private CancellationTokenSource? _polling;
    private TimeSpan _pollInterval = TimeSpan.FromSeconds(10);
    private bool _pollInProgress;
    private bool _statusFailureReported;
    private bool _silentReconcile;

    public TunnelManager(ITunnelService service, IServiceProbe probe, ConfigStore configs, RecoverableJsonStore<List<Tunnel>> store,
        LogService log, INotifier notifier, Func<bool> notificationsEnabled, TimeProvider? time = null,
        INetworkInfo? network = null, RecoverableJsonStore<List<HopChain>>? hopChains = null, IInventoryRunner? inventory = null,
        Func<bool>? canAdminister = null)
    {
        _canAdminister = canAdminister ?? (() => false);
        _inventory = inventory ?? new InventoryCommandRunner();
        _network = network ?? new SystemNetworkInfo();
        _hopChainStore = hopChains;
        _service = service;
        _probe = probe;
        _configs = configs;
        _store = store;
        _log = log;
        _notifier = notifier;
        _notificationsEnabled = notificationsEnabled;
        _time = time ?? TimeProvider.System;
    }

    /// Raised after any change of the tunnels or their runtime state (several times a second at most).
    public event Action? StateChanged;

    [ObservableProperty] private string? _errorMessage;
    [ObservableProperty] private SetupState _setupState = SetupState.Checking;
    [ObservableProperty] private string? _setupDetail;
    [ObservableProperty] private string? _serviceVersion;
    [ObservableProperty] private bool _isInitialized;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private bool _isShuttingDown;
    [ObservableProperty] private IReadOnlyList<TunnelWarning> _warnings = [];

    public IReadOnlyList<Tunnel> Tunnels => _tunnels;
    public bool HasActiveTunnels => _tunnels.Any(t => t.IsActive);
    public int ActiveTunnelCount => _tunnels.Count(t => t.IsActive);
    public IEnumerable<Tunnel> FavoriteTunnels => _tunnels.Where(t => t.IsFavorite && t.Scope == TunnelScope.Personal);
    public IEnumerable<Tunnel> SharedTunnels => _tunnels.Where(t => t.Scope == TunnelScope.Managed);
    public bool NeedsSetup => SetupState != SetupState.Ready;
    public bool CanConnectTunnels => SetupState == SetupState.Ready && !IsShuttingDown;
    public string? QuitFailureReason => _shutdown.FailureReason;
    public ConnectionStatus TrayStatus => _feedback.TrayStatus(HasActiveTunnels);

    public string? ConnectionUnavailableReason => SetupState switch
    {
        SetupState.Ready => IsShuttingDown ? "WireTunnels is quitting." : null,
        SetupState.Checking => "Checking the WireTunnels service…",
        SetupState.ServiceMissing => "The WireTunnels service is not installed.",
        SetupState.ServiceStopped => "The WireTunnels service is stopped.",
        SetupState.ServiceStarting => "The WireTunnels service is starting…",
        SetupState.Incompatible => SetupDetail ?? "The WireTunnels service belongs to another version of WireTunnels.",
        _ => SetupDetail ?? "The WireTunnels service does not respond.",
    };

    public Tunnel? Find(Guid id) => _tunnels.FirstOrDefault(t => t.Id == id);
    public bool IsBusy(Guid id) => _connecting.Contains(id) || _disconnecting.Contains(id);
    public ConnectionStatus? ConnectionStatusOf(Guid id) => _feedback.Status(id);
    public IReadOnlyList<TrafficSample> TrafficOf(Guid id) => _traffic.TryGetValue(id, out var s) ? s : [];
    public DateTimeOffset Now => _time.GetUtcNow();

    // MARK: - Initialization

    public async Task InitializeAsync()
    {
        IsLoading = true;
        try
        {
            try
            {
                _tunnels = _store.Load();
                if (_store.RecoveryWarning is { } warning) ReportStorageIssue(warning);
            }
            catch (IOException e)
            {
                // RecoverableJsonStore left the files untouched; saving stays refused until they are fixed.
                ReportStorageIssue(e.Message);
                _tunnels = [];
            }
            _log.Info($"Loaded {_tunnels.Count} tunnel(s)");
            LoadHopChains();
            await RefreshServiceStateAsync();
            if (SetupState == SetupState.Ready)
            {
                await LoadManagedTunnelsAsync();
                await LoadSystemSettingsAsync();
            }
            // Reconcile silently: a tunnel saved as active that is gone after a reboot or a service
            // restart while the app was closed is simply disconnected, not a "connection lost".
            _silentReconcile = true;
            try { if (SetupState == SetupState.Ready) await RefreshStatusAsync(reportError: false); }
            finally { _silentReconcile = false; }
            if (SetupState == SetupState.Ready) await RestoreNetworkStateAsync();
        }
        finally
        {
            IsLoading = false;
            IsInitialized = true;
            UpdateWarnings();
            Notify();
        }
    }

    /// Probes the Windows service and, when it runs, checks that it speaks our protocol.
    public async Task RefreshServiceStateAsync()
    {
        var previous = SetupState;
        var (state, detail) = _probe.Query() switch
        {
            ServiceInstallState.NotInstalled => (SetupState.ServiceMissing, (string?)null),
            ServiceInstallState.Stopped => (SetupState.ServiceStopped, null),
            ServiceInstallState.Starting => (SetupState.ServiceStarting, null),
            _ => await HandshakeAsync(),
        };
        SetupDetail = detail;
        SetupState = state;
        if (state != previous)
        {
            var message = $"Service state: {state}{(detail is null ? "" : $" ({detail})")}";
            if (state == SetupState.Ready) _log.Info($"{message}, version {ServiceVersion}");
            else _log.Warning(message);
            OnPropertyChanged(nameof(ConnectionUnavailableReason));
            OnPropertyChanged(nameof(CanConnectTunnels));
            Notify();
        }
    }

    private async Task<(SetupState, string?)> HandshakeAsync()
    {
        try
        {
            ServiceVersion = await _service.HandshakeAsync();
            return (SetupState.Ready, null);
        }
        catch (ServiceProtocolException e) { return (SetupState.Incompatible, e.Message); }
        catch (Exception e) when (e is ServiceException or IOException or TimeoutException or UnauthorizedAccessException)
        {
            return (SetupState.Unreachable, e.Message);
        }
    }

    // MARK: - Connect / disconnect

    /// `suppressDns` keeps the tunnel's DNS off the adapter (a multi-hop hop leg).
    public async Task ConnectAsync(Guid id, bool automatic = false, bool suppressDns = false)
    {
        if (Find(id) is not { } tunnel) return;
        if (ChainConflict(id) is { } chainConflict)
        {
            _log.Warning(chainConflict);
            ReportFailure(tunnel, chainConflict, automatic);
            return;
        }
        if (!CanConnectTunnels)
        {
            if (IsShuttingDown) return;
            var reason = ConnectionUnavailableReason ?? "WireTunnels is not ready to connect.";
            _log.Warning(reason);
            ReportFailure(tunnel, reason, automatic);
            return;
        }
        if (tunnel.Scope == TunnelScope.Managed && tunnel.ManagedPolicy?.UsersCanConnect == false)
        {
            ReportFailure(tunnel, "Users are not allowed to connect this managed tunnel", automatic);
            return;
        }
        if (IsBusy(id))
        {
            _log.Info($"Connect already in progress for {tunnel.Name}, skipping");
            return;
        }

        _connecting.Add(id);
        _feedback.Begin(id, reconnecting: _feedback.Issues.ContainsKey(id));
        Notify();
        var watch = Stopwatch.StartNew();
        _log.Info($"{(automatic ? "Auto-connecting" : "Starting")} tunnel: {tunnel.Name}");
        try
        {
            var alias = AliasOf(tunnel) ?? throw new InvalidDataException("The tunnel's configuration file is missing.");
            if (tunnel.Scope == TunnelScope.Managed)
            {
                // The service starts it from its own copy and applies its split DNS; we only see the metadata.
                await _log.TimedAsync($"Connect {tunnel.Name}: starting shared tunnel", () => _service.StartManagedAsync(tunnel.Id));
                _runningRouting[id] = new([.. tunnel.Address ?? []], [.. tunnel.AllowedIPs], [.. tunnel.Dns]);
            }
            else
            {
                var contents = _configs.Read(tunnel.ConfigPath);
                var parsed = WireGuardConfig.Parse(contents);
                if (!parsed.IsValid) throw new ConfigValidationException(parsed.Errors.Select(e => e.Message));
                // Inventory destinations are blocked before the tunnel comes up; AfterConnectAsync opens them through it.
                if (tunnel.InventoryCommand is not null) await ProtectInventoryAsync(tunnel);
                // Split DNS replaces the adapter's DNS with NRPT rules for its domains, set after the connect.
                var withoutDns = suppressDns || tunnel.EffectiveSplitDNSDomains.Count > 0;
                await _log.TimedAsync($"Connect {tunnel.Name}: starting WireGuard", () => _service.StartAsync(alias, contents, withoutDns));
                _runningRouting[id] = new([.. parsed.Address], [.. parsed.PrimaryPeer?.AllowedIPs ?? []], [.. parsed.Dns]);
            }

            if (Find(id) is not { } live) throw new InvalidOperationException("The tunnel was removed while connecting.");
            live.IsActive = true;
            live.ConnectedAt = Now;
            live.InterfaceName = alias;
            live.UpdatedAt = Now;
            SavePersonalTunnels();
            UpdateWarnings();

            var confirmed = await RefreshStatusAsync(reportError: !automatic);
            await AfterConnectAsync(id);
            var active = Find(id)?.IsActive == true;
            _feedback.CompleteConnection(id, confirmed && active);
            if (confirmed && active)
            {
                _log.Info($"Tunnel {tunnel.Name} connected in {Seconds(watch)}s; interface={alias}");
                if (!automatic && _notificationsEnabled()) _notifier.Connected(tunnel.Name);
            }
            else _log.Warning($"Tunnel {tunnel.Name}: startup completed but runtime connection is unconfirmed");
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            _log.Error($"Failed to connect {tunnel.Name} after {Seconds(watch)}s: {e.Message}");
            ReportFailure(tunnel, $"Failed to connect {tunnel.Name}: {e.Message}", automatic);
        }
        finally
        {
            _connecting.Remove(id);
            _feedback.Finish(id);
            Notify();
        }
    }

    public async Task<bool> DisconnectAsync(Guid id, bool automatic = false)
    {
        if (Find(id) is not { } tunnel) return false;
        if (ChainConflict(id) is { } chainConflict)
        {
            _log.Warning(chainConflict);
            ReportFailure(tunnel, chainConflict, automatic);
            return false;
        }
        if (IsBusy(id)) return false;
        if (tunnel.Scope == TunnelScope.Managed && tunnel.ManagedPolicy?.UsersCanDisconnect == false)
        {
            ReportFailure(tunnel, "Users are not allowed to disconnect this managed tunnel", automatic);
            return false;
        }
        _disconnecting.Add(id);
        Notify();
        var watch = Stopwatch.StartNew();
        _log.Info($"{(automatic ? "Auto-disconnecting" : "Stopping")} tunnel: {tunnel.Name}");
        try
        {
            var alias = tunnel.InterfaceName ?? AliasOf(tunnel)
                ?? throw new InvalidDataException("The tunnel's interface is unknown.");
            if (tunnel.InventoryCommand is not null) await ProtectInventoryAsync(tunnel);
            await _service.StopAsync(alias);
            FinalizeStopped(tunnel);
            await AfterDisconnectAsync(tunnel);
            _log.Info($"Tunnel {tunnel.Name} disconnected in {Seconds(watch)}s");
            if (!automatic && !IsShuttingDown && _notificationsEnabled()) _notifier.Disconnected(tunnel.Name);
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            _log.Error($"Failed to disconnect {tunnel.Name} after {Seconds(watch)}s: {e.Message}");
            ReportFailure(tunnel, $"Failed to disconnect {tunnel.Name}: {e.Message}", automatic);
            return false;
        }
        finally
        {
            _disconnecting.Remove(id);
            Notify();
        }
    }

    /// Shared tunnels too, as on macOS (quit and reset stop them for every user, as their policy allows).
    public async Task<bool> StopAllActiveAsync()
    {
        var succeeded = true;
        // Chains as a unit first: their legs refuse to stop one by one.
        foreach (var chain in _hopChains.Where(IsChainActive).ToList())
            if (!await DisconnectHopChainAsync(chain.Id)) succeeded = false;
        foreach (var tunnel in _tunnels.Where(t => t.IsActive).ToList())
            if (!await DisconnectAsync(tunnel.Id)) succeeded = false;
        return succeeded;
    }

    public async Task StartAllFavoritesAsync()
    {
        foreach (var tunnel in FavoriteTunnels.Where(t => !t.IsActive).ToList()) await ConnectAsync(tunnel.Id);
    }

    private void FinalizeStopped(Tunnel tunnel)
    {
        ClearRuntime(tunnel);
        tunnel.UpdatedAt = Now;
        SavePersonalTunnels();
        UpdateWarnings();
        _feedback.Disconnected(tunnel.Id);
    }

    private void ClearRuntime(Tunnel tunnel)
    {
        tunnel.IsActive = false;
        tunnel.ConnectedAt = null;
        tunnel.InterfaceName = null;
        tunnel.LastHandshake = null;
        tunnel.RxBytes = 0;
        tunnel.TxBytes = 0;
        _traffic.Remove(tunnel.Id);
        _trafficSnapshots.Remove(tunnel.Id);
    }

    private void ReportFailure(Tunnel tunnel, string message, bool automatic)
    {
        if (_feedback.Failed(tunnel.Id, message, automatic) is { } alert)
        {
            ErrorMessage = alert;
            if (_notificationsEnabled()) _notifier.Failed(tunnel.Name, message);
        }
        Notify();
    }

    // MARK: - Status

    /// Merges the service's runtime snapshot into the tunnels. The adapter name is the config alias,
    /// so matching is exact (macOS needs key-based matching because utun names change).
    public async Task<bool> RefreshStatusAsync(bool reportError = true)
    {
        IReadOnlyList<TunnelRuntimeStatus> statuses;
        try
        {
            statuses = await _service.StatusAsync();
        }
        catch (Exception e) when (e is ServiceException or IOException or TimeoutException or UnauthorizedAccessException)
        {
            if (!reportError)
            {
                if (!_statusFailureReported) _log.Info($"Status refresh waiting for the service: {e.Message}; preserving last known tunnel state");
            }
            else if (!_statusFailureReported)
            {
                ErrorMessage = $"Unable to refresh tunnel status: {e.Message}";
                _log.Warning($"{ErrorMessage}; preserving last known tunnel state");
            }
            _statusFailureReported = true;
            await RefreshServiceStateAsync();
            return false;
        }
        _statusFailureReported = false;

        var byName = statuses.ToDictionary(s => s.Name, StringComparer.Ordinal);
        var matched = new HashSet<string>(StringComparer.Ordinal);
        var reconciled = false;
        var lost = false;
        foreach (var tunnel in _tunnels)
        {
            var alias = tunnel.InterfaceName ?? AliasOf(tunnel);
            if (alias is not null && byName.TryGetValue(alias, out var status))
            {
                matched.Add(alias);
                if (!_connecting.Contains(tunnel.Id) && _feedback.Issues.ContainsKey(tunnel.Id)) _feedback.Connected(tunnel.Id);
                if (!tunnel.IsActive) _log.Info($"Status {tunnel.Name}: matched adapter {alias}");
                tunnel.IsActive = true;
                tunnel.InterfaceName = alias;
                tunnel.ConnectedAt ??= Now;
                if (status.Peers.FirstOrDefault() is { } peer)
                {
                    tunnel.LastHandshake = peer.LastHandshake;
                    tunnel.RxBytes = peer.RxBytes;
                    tunnel.TxBytes = peer.TxBytes;
                    if (peer.AllowedIPs.Count > 0) tunnel.AllowedIPs = peer.AllowedIPs;
                    if (peer.Endpoint is { } endpoint) tunnel.Endpoint = endpoint;
                    RecordTraffic(tunnel.Id, peer.RxBytes, peer.TxBytes);
                }
            }
            else if (tunnel.IsActive)
            {
                if (!_connecting.Contains(tunnel.Id) && !_disconnecting.Contains(tunnel.Id) && !_silentReconcile) _feedback.Lost(tunnel.Id);
                _log.Info($"Status {tunnel.Name}: adapter no longer present in the service snapshot");
                ClearRuntime(tunnel);
                lost = true;
                if (_silentReconcile) reconciled = true;
            }
        }
        _unrecognizedRuntimeTunnels = statuses.Select(s => s.Name).Where(n => !matched.Contains(n)).ToList();
        if (reconciled) SavePersonalTunnels();
        UpdateWarnings();
        Notify();
        // A lost tunnel's split DNS rules go; an armed kill switch stays and blocks (KillSwitchBlocking).
        if (lost) await SyncSplitDnsStateAsync();
        return true;
    }

    /// Polls status (and the service while setup is needed). 2 s with the dashboard open, 10 s otherwise.
    public void StartPolling(TimeSpan interval)
    {
        if (IsShuttingDown) return;
        _pollInterval = interval;
        _polling?.Cancel();
        var cts = _polling = new CancellationTokenSource();
        _ = PollAsync(interval, cts.Token);
    }

    public void StopPolling()
    {
        _polling?.Cancel();
        _polling = null;
    }

    private async Task PollAsync(TimeSpan interval, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(interval, _time, ct); }
            catch (OperationCanceledException) { return; }
            if (IsShuttingDown) return;
            if (IsLoading || _pollInProgress) continue;
            _pollInProgress = true;
            try
            {
                if (NeedsSetup) await RefreshServiceStateAsync();
                if (SetupState == SetupState.Ready)
                {
                    // Shared tunnels change under us (an administrator, another user): refresh them every 10 s, like macOS.
                    if (Now - _managedLoadedAt >= ManagedRefreshInterval) await LoadManagedTunnelsAsync();
                    await RefreshStatusAsync(reportError: false);
                }
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                _log.Error($"Status poll failed: {e.Message}");
            }
            finally { _pollInProgress = false; }
        }
    }

    private void RecordTraffic(Guid id, long rx, long tx)
    {
        var now = Now;
        if (_trafficSnapshots.TryGetValue(id, out var previous))
        {
            var seconds = (now - previous.Time).TotalSeconds;
            if (seconds < 0.5) return; // keep the older baseline
            var samples = _traffic.TryGetValue(id, out var list) ? list : _traffic[id] = [];
            samples.Add(new TrafficSample(now, Math.Max(0, (rx - previous.Rx) / seconds), Math.Max(0, (tx - previous.Tx) / seconds)));
            if (samples.Count > MaxTrafficSamples) samples.RemoveRange(0, samples.Count - MaxTrafficSamples);
        }
        _trafficSnapshots[id] = (rx, tx, now);
    }

    private void UpdateWarnings() => Warnings = TunnelWarnings.Compute(_tunnels, _killSwitchArmed, CurrentLeakWarnings());

    // MARK: - Config management

    /// Validates a `.conf` the user picked, without importing it.
    public static WireGuardConfig Inspect(string path) => WireGuardConfig.Parse(ConfigStore.ReadSource(path));

    public Tunnel Import(string path)
    {
        _log.Info($"Importing config: {Path.GetFileName(path)}");
        var tunnel = Create(Path.GetFileNameWithoutExtension(path), ConfigStore.ReadSource(path));
        _log.Info($"Imported tunnel: {tunnel.Name}");
        return tunnel;
    }

    public Tunnel Create(string name, string contents)
    {
        var parsed = WireGuardConfig.Parse(contents);
        if (!parsed.IsValid) throw new ConfigValidationException(parsed.Errors.Select(e => e.Message));
        var displayName = ConfigName.DisplayName(name);
        var path = _configs.Save(displayName, contents);
        var tunnel = new Tunnel { Name = displayName, ConfigPath = path, CreatedAt = Now, UpdatedAt = Now };
        Apply(parsed, tunnel);
        try
        {
            PersistPersonalTunnels([.. _tunnels, tunnel]);
        }
        catch
        {
            _configs.Delete(path);
            throw;
        }
        _tunnels = [.. _tunnels, tunnel];
        RetainFeedback();
        UpdateWarnings();
        _log.Info($"Created tunnel: {displayName}");
        Notify();
        return tunnel;
    }

    public string ReadConfig(Guid id) =>
        _configs.Read((Find(id) ?? throw new InvalidOperationException("The tunnel no longer exists.")).ConfigPath);

    /// A saved edit takes effect on the next connect, as on macOS.
    public void Update(Guid id, string name, string contents)
    {
        if (IsBusy(id)) throw new InvalidOperationException("Wait for the current operation on this tunnel to finish.");
        if (Find(id) is not { } tunnel) return;
        if (tunnel.InventoryCommand is not null)
            throw new InvalidOperationException("Disable inventory protection before editing this tunnel's configuration.");
        var parsed = WireGuardConfig.Parse(contents);
        if (!parsed.IsValid) throw new ConfigValidationException(parsed.Errors.Select(e => e.Message));

        var displayName = ConfigName.DisplayName(name);
        var oldPath = tunnel.ConfigPath;
        var samePath = string.Equals(_configs.PathFor(displayName), oldPath, StringComparison.OrdinalIgnoreCase);
        var oldBytes = _configs.ReadRaw(oldPath);
        var newPath = _configs.Save(displayName, contents, replacingExisting: samePath);

        var updated = Clone(tunnel);
        updated.Name = displayName;
        updated.ConfigPath = newPath;
        Apply(parsed, updated);
        updated.UpdatedAt = Now;
        var list = _tunnels.Select(t => t.Id == id ? updated : t).ToList();
        try
        {
            PersistPersonalTunnels(list);
        }
        catch
        {
            if (samePath)
            {
                try { _configs.WriteRaw(oldPath, oldBytes); }
                catch (IOException e) { ReportStorageIssue($"Unable to restore the original config after a metadata save failure: {e.Message}"); }
            }
            else _configs.Delete(newPath);
            throw;
        }
        // Keep live runtime fields (the running adapter keeps its old alias until reconnect).
        CopyRuntime(tunnel, updated);
        _tunnels = list;
        if (!samePath) _configs.Delete(oldPath);
        UpdateWarnings();
        _log.Info($"Updated tunnel: {displayName}");
        Notify();
    }

    /// Port of TunnelDuplicationService: a disconnected copy named `<name>_copy[_n]`.
    public Tunnel Duplicate(Guid id)
    {
        if (Find(id) is not { } source) throw new InvalidOperationException("The tunnel no longer exists.");
        if (source.Scope != TunnelScope.Personal) throw new InvalidOperationException("Only personal tunnels can be duplicated.");
        var contents = _configs.Read(source.ConfigPath);
        var parsed = WireGuardConfig.Parse(contents);
        if (!parsed.IsValid) throw new ConfigValidationException(parsed.Errors.Select(e => e.Message));

        var names = _tunnels.Select(t => t.Name.ToLowerInvariant()).ToHashSet();
        var aliases = _tunnels.SelectMany(t => new[] { AliasOf(t), t.InterfaceName })
            .Concat(_unrecognizedRuntimeTunnels).OfType<string>().Select(a => a.ToLowerInvariant()).ToHashSet();
        var baseName = ConfigName.DisplayName(source.Name);
        for (var number = 1; ; number++)
        {
            var suffix = number == 1 ? "_copy" : $"_copy_{number}";
            var room = ConfigName.MaxDisplayLength - suffix.Length;
            var info = new System.Globalization.StringInfo(baseName);
            var candidate = (info.LengthInTextElements > room ? info.SubstringByTextElements(0, room) : baseName) + suffix;
            if (names.Contains(candidate.ToLowerInvariant()) || aliases.Contains(ConfigName.FileBaseName(candidate).ToLowerInvariant())) continue;
            if (_configs.Exists(candidate)) continue;
            var copy = Create(candidate, contents);
            copy.KillSwitchEnabled = source.KillSwitchEnabled;
            copy.IpFamilyLeakWarningAcknowledged = source.IpFamilyLeakWarningAcknowledged;
            copy.ExcludedRoutes = [.. source.ExcludedRoutes];
            copy.SplitDNSDomains = [.. source.SplitDNSDomains];
            copy.SpeedTestURL = source.SpeedTestURL;
            copy.AutoConnectRule = System.Text.Json.JsonSerializer.Deserialize<AutoConnectRule>(
                System.Text.Json.JsonSerializer.Serialize(source.AutoConnectRule, CoreJson.Options), CoreJson.Options) ?? new();
            copy.AutoConnectRule.Connect.Enabled = false;
            copy.AutoConnectRule.Disconnect.Enabled = false;
            SavePersonalTunnels();
            _log.Info($"Duplicated tunnel: {source.Name} -> {copy.Name}");
            return copy;
        }
    }

    public void Delete(Guid id)
    {
        if (Find(id) is not { } tunnel || tunnel.Scope != TunnelScope.Personal) return;
        if (tunnel.IsActive || IsBusy(id))
        {
            ErrorMessage = $"Disconnect {tunnel.Name} before deleting it.";
            return;
        }
        if (tunnel.InventoryCommand is not null)
        {
            ErrorMessage = "Disable inventory protection before deleting this tunnel.";
            return;
        }
        var list = _tunnels.Where(t => t.Id != id).ToList();
        try { PersistPersonalTunnels(list); }
        catch (IOException e)
        {
            ReportStorageIssue($"Unable to delete saved tunnel: {e.Message}");
            return;
        }
        _tunnels = list;
        _configs.Delete(tunnel.ConfigPath);
        if (_hopChains.Any(c => c.HopTunnelID == id || c.ExitTunnelID == id))
            SaveHopChains(_hopChains.Where(c => c.HopTunnelID != id && c.ExitTunnelID != id).ToList());
        RetainFeedback();
        UpdateWarnings();
        _log.Info($"Deleted tunnel: {tunnel.Name}");
        Notify();
    }

    public void ToggleFavorite(Guid id)
    {
        if (Find(id) is not { Scope: TunnelScope.Personal } tunnel) return;
        tunnel.IsFavorite = !tunnel.IsFavorite;
        SavePersonalTunnels();
        Notify();
    }

    /// No built-in default host: empty disables the throughput probe.
    public void UpdateSpeedTestUrl(Guid id, string? url)
    {
        if (Find(id) is not { Scope: TunnelScope.Personal } tunnel) return;
        tunnel.SpeedTestURL = string.IsNullOrWhiteSpace(url) ? null : url.Trim();
        tunnel.UpdatedAt = Now;
        SavePersonalTunnels();
        Notify();
    }

    public Task<ConnectionTestResult> TestConnectionAsync(Guid id, CancellationToken ct = default) =>
        Find(id) is { } tunnel
            ? ConnectionTester.TestAsync(tunnel.Endpoint, tunnel.SpeedTestURL, ct)
            : Task.FromResult<ConnectionTestResult>(new ConnectionTestResult.UnknownEndpoint());

    private void Apply(WireGuardConfig parsed, Tunnel tunnel)
    {
        var peer = parsed.PrimaryPeer;
        tunnel.Address = [.. parsed.Address];
        tunnel.AllowedIPs = [.. peer?.AllowedIPs ?? []];
        tunnel.Dns = [.. parsed.Dns];
        tunnel.Endpoint = peer?.Endpoint;
        tunnel.PublicKey = peer?.PublicKey;
        tunnel.LocalPublicKey = parsed.PrivateKey is { } key ? WireGuardKey.PublicKey(key) : null;
    }

    private static Tunnel Clone(Tunnel tunnel) =>
        System.Text.Json.JsonSerializer.Deserialize<Tunnel>(System.Text.Json.JsonSerializer.Serialize(tunnel, CoreJson.Options), CoreJson.Options)!;

    private static void CopyRuntime(Tunnel from, Tunnel to)
    {
        to.IsActive = from.IsActive;
        to.ConnectedAt = from.ConnectedAt;
        to.InterfaceName = from.InterfaceName;
        to.LastHandshake = from.LastHandshake;
        to.RxBytes = from.RxBytes;
        to.TxBytes = from.TxBytes;
        if (from.IsActive) { to.AllowedIPs = from.AllowedIPs; to.Endpoint = from.Endpoint; }
    }

    private void RetainFeedback() => _feedback.Retain(_tunnels.Select(t => t.Id).ToHashSet());

    /// Port of resetUserData: stops every tunnel, removes inventory protection (it would otherwise outlive the
    /// tunnels it belongs to), then deletes configs, metadata and the log. Settings are the caller's.
    public async Task<bool> ResetUserDataAsync(AppPaths paths)
    {
        var stopped = await StopAllActiveAsync();
        var stopFailures = _tunnels.Where(t => t.IsActive).Select(t => t.Name).ToList();
        try
        {
            if (_tunnels.Any(t => t.InventoryCommand is not null))
            {
                if (!stopped) throw new InventoryException("Disconnect all inventory tunnels before resetting app data");
                foreach (var tunnel in _tunnels.Where(t => t.InventoryCommand is not null).ToList()) await UpdateInventoryCommandAsync(tunnel.Id, null);
            }
            foreach (var directory in new[] { paths.Configs, paths.Metadata })
                if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InventoryException || IsServiceFailure(e))
        {
            ErrorMessage = $"Reset app data failed: {e.Message}";
            _log.Error(ErrorMessage);
            return false;
        }
        _tunnels = _tunnels.Where(t => t.Scope == TunnelScope.Managed).ToList();
        _hopChains = [];
        _traffic.Clear();
        _trafficSnapshots.Clear();
        _runningRouting.Clear();
        _killSwitchArmed.Clear();
        _killSwitchEntries.Clear();
        _inventoryErrors.Clear();
        _lastSplitDns = null;
        RetainFeedback();
        _log.Clear();
        ErrorMessage = stopFailures.Count > 0
            ? $"App data was reset, but these tunnels could not be stopped: {string.Join(", ", stopFailures)}."
            : null;
        UpdateWarnings();
        Notify();
        return true;
    }

    // MARK: - Persistence

    private void PersistPersonalTunnels(List<Tunnel> tunnels) =>
        _store.Save(tunnels.Where(t => t.Scope == TunnelScope.Personal).ToList());

    private void SavePersonalTunnels()
    {
        try { PersistPersonalTunnels(_tunnels); }
        catch (IOException e) { ReportStorageIssue($"Unable to save tunnels: {e.Message}"); }
    }

    private void ReportStorageIssue(string message)
    {
        _log.Error(message);
        ErrorMessage = message;
    }

    private void Notify() => StateChanged?.Invoke();

    private static string Seconds(Stopwatch watch) =>
        watch.Elapsed.TotalSeconds.ToString("0.000", System.Globalization.CultureInfo.InvariantCulture);

    // MARK: - Quit (IShutdownClient)

    public Task<bool> PrepareForQuitAsync() => _shutdown.PrepareAsync(this);
    public Task CancelQuitAsync() => _shutdown.CancelAsync(this);

    void IShutdownClient.BeginShutdown()
    {
        IsShuttingDown = true;
        StopPolling();
        OnPropertyChanged(nameof(CanConnectTunnels));
        _log.Info("Quit: waiting for pending operations before disconnecting tunnels");
        Notify();
    }

    Task IShutdownClient.CancelShutdownAsync()
    {
        IsShuttingDown = false;
        OnPropertyChanged(nameof(CanConnectTunnels));
        StartPolling(_pollInterval);
        Notify();
        return Task.CompletedTask;
    }

    async Task<bool> IShutdownClient.WaitForPendingOperationsAsync()
    {
        var deadline = Stopwatch.StartNew();
        while (!IsInitialized || IsLoading || _connecting.Count > 0 || _disconnecting.Count > 0 || _pollInProgress)
        {
            if (deadline.Elapsed > PendingOperationsDeadline) return false;
            await Task.Delay(50);
        }
        return true;
    }

    async Task<bool> IShutdownClient.RefreshForShutdownAsync()
    {
        await RefreshServiceStateAsync();
        // Closing an adapter handle removes it, so a stopped or missing service has no tunnels left.
        if (SetupState is SetupState.ServiceMissing or SetupState.ServiceStopped)
        {
            foreach (var tunnel in _tunnels.Where(t => t.IsActive)) ClearRuntime(tunnel);
            SavePersonalTunnels();
            Notify();
            return true;
        }
        if (SetupState != SetupState.Ready)
        {
            ErrorMessage = "The WireTunnels service does not respond, so connected tunnels cannot be confirmed and stopped.";
            return false;
        }
        if (!await RefreshStatusAsync(reportError: false)) return false;
        if (_unrecognizedRuntimeTunnels.Count > 0)
        {
            ErrorMessage = $"A running WireTunnels tunnel ({string.Join(", ", _unrecognizedRuntimeTunnels)}) could not be matched to a saved tunnel. "
                + "Stop it with \"wiretunnels disconnect <name>\" before quitting.";
            return false;
        }
        return true;
    }

    Task<bool> IShutdownClient.DisconnectForShutdownAsync() => StopAllActiveAsync();

    Task<bool> IShutdownClient.RestoreNetworkSettingsForShutdownAsync() => RestoreNetworkForShutdownAsync();
}
