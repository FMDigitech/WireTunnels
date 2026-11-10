using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Storage;

namespace WireTunnels.Client;

/// Phase 6: On-Demand rules and recovery, port of NetworkMonitorService / NetworkChangeScheduler and the
/// handleNetworkChange / handleSystemWake / checkEndpointReResolution half of TunnelManager.swift.
/// Recovery differs from macOS on purpose: wireguard-nt keeps its socket across sleep and DHCP renewals and
/// roams with the default route, so the app does not restart every tunnel. It restarts only a tunnel whose
/// endpoint resolves to a new address (DDNS), and re-adds the routes that depend on the physical gateway
/// (split tunnel exclusions, multi-hop) when the gateway changes.
public sealed partial class TunnelManager
{
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan WakeSettle = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan EndpointRecheckInterval = TimeSpan.FromSeconds(60);

    private INetworkMonitor? _monitor;
    private SynchronizationContext? _context;
    private PhysicalNetwork _physical = PhysicalNetwork.None;
    private bool _physicalRead;
    /// Connected by a rule, not by the user (macOS autoConnectedIDs).
    private readonly HashSet<Guid> _autoConnected = [];
    /// Disconnected by the user while a rule matched: no reconnect until the network stops matching.
    private readonly HashSet<Guid> _suppressed = [];
    /// The configured endpoint of each running tunnel (the status poll replaces Tunnel.Endpoint with the live one).
    private readonly Dictionary<Guid, string> _configuredEndpoints = [];
    private DateTimeOffset _endpointsCheckedAt = DateTimeOffset.MinValue;
    private Task? _scheduled;
    private bool _rulesPending, _gatewayPending, _restarting;
    /// Environment.TickCount64 of the last event: the debounce runs on the real clock, not the injected TimeProvider.
    private long _lastEventTick;

    public PhysicalNetwork PhysicalNetwork => _physical;

    /// Starts listening and applies the rules to the current network; call once from the UI thread after
    /// InitializeAsync (later events are marshalled back to it).
    public async Task StartAutomationAsync(INetworkMonitor monitor)
    {
        _monitor = monitor;
        _context = SynchronizationContext.Current;
        monitor.Changed += () => Post(() => RefreshNetworkStateAsync());
        monitor.Woke += () => Post(HandleWakeAsync);
        await RefreshNetworkStateAsync(evaluate: false);
        await EvaluateRulesWhenIdleAsync();
    }

    private void Post(Func<Task> action)
    {
        if (_context is null) _ = action();
        else _context.Post(_ => _ = action(), null);
    }

    public bool MatchesConnect(Tunnel t) => Matches(t.AutoConnectRule.Connect);
    public bool MatchesDisconnect(Tunnel t) => Matches(t.AutoConnectRule.Disconnect);

    private bool Matches(AutoConnectNetworkMatch rule) =>
        rule.Matches(_physical.IsOnEthernet, [.. _physical.EthernetAddresses], _physical.IsOnWiFi, _physical.Ssid);

    /// Reads the physical network and schedules rule evaluation (and a gateway route refresh) when it matters.
    public async Task RefreshNetworkStateAsync(bool evaluate = true)
    {
        if (_monitor is not { } monitor || IsShuttingDown) return;
        var adapters = _tunnels.Select(t => t.InterfaceName).OfType<string>().ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (await Task.Run(() => monitor.Read(adapters)) is not { } now) return;
        var previous = _physical;
        var first = !_physicalRead;
        _physical = now;
        _physicalRead = true;
        var rulesChanged = first || now.RulesInputsDiffer(previous) || now.WiFiNameDenied != previous.WiFiNameDenied;
        var gatewayChanged = !first && !now.Gateways.SequenceEqual(previous.Gateways);
        if (!rulesChanged && !gatewayChanged) return;
        _log.Info($"Physical network change: wifi={now.IsOnWiFi}, ethernet={now.IsOnEthernet}{(gatewayChanged ? ", gateway changed" : "")}");
        Notify();
        if (evaluate) Schedule(gatewayChanged);
    }

    /// Port of NetworkChangeScheduler: bursts settle for a full debounce interval, then rules run, then (if the
    /// gateway changed) the gateway routes are refreshed and rules run once more. One sequence at a time.
    private void Schedule(bool gatewayChanged)
    {
        _rulesPending = true;
        _gatewayPending |= gatewayChanged;
        _lastEventTick = Environment.TickCount64;
        _scheduled ??= ProcessScheduledAsync();
    }

    private async Task ProcessScheduledAsync()
    {
        try
        {
            while (_rulesPending && !IsShuttingDown)
            {
                for (long elapsed; (elapsed = Environment.TickCount64 - _lastEventTick) < (long)Debounce.TotalMilliseconds;)
                    await Task.Delay(TimeSpan.FromMilliseconds(Debounce.TotalMilliseconds - elapsed));
                var gateway = _gatewayPending;
                _rulesPending = _gatewayPending = false;
                await EvaluateRulesWhenIdleAsync();
                if (!gateway) continue;
                await RefreshGatewayRoutesAsync();
                await EvaluateRulesWhenIdleAsync();
            }
        }
        finally { _scheduled = null; }
    }

    /// A manual connect, a restart or a disconnect may be running: act on its confirmed result.
    private async Task EvaluateRulesWhenIdleAsync()
    {
        while (_connecting.Count > 0 || _disconnecting.Count > 0 || _connectingChains.Count > 0 || _restarting)
        {
            if (IsShuttingDown) return;
            await Task.Delay(50);
        }
        await EvaluateRulesAsync();
    }

    /// Port of handleNetworkChange. Disconnect wins when both halves match.
    public async Task EvaluateRulesAsync()
    {
        if (IsShuttingDown || IsLoading || NeedsSetup || !_physicalRead) return;
        foreach (var tunnel in _tunnels.ToList())
        {
            if (IsShuttingDown) return;
            if (Find(tunnel.Id) is not { AutoConnectRule.Enabled: true } t) continue;
            var policy = t.Scope == TunnelScope.Managed ? t.ManagedPolicy ?? new() : null;
            if (MatchesDisconnect(t))
            {
                if (t.IsActive && policy?.UsersCanDisconnect != false)
                {
                    _log.Info($"Auto-disconnect rule triggered for {t.Name}");
                    if (await DisconnectAsync(t.Id, automatic: true)) _autoConnected.Remove(t.Id);
                }
            }
            else if (MatchesConnect(t))
            {
                if (!t.IsActive && !_suppressed.Contains(t.Id) && !IsBusy(t.Id) && policy?.UsersCanConnect != false)
                {
                    _log.Info($"Auto-connect rule triggered for {t.Name}");
                    _autoConnected.Add(t.Id);
                    await ConnectAsync(t.Id, automatic: true);
                }
            }
            else
            {
                // Neither half matches: the next matching network connects it again.
                _suppressed.Remove(t.Id);
                if (t.IsActive && _autoConnected.Contains(t.Id) && policy?.UsersCanDisconnect != false)
                {
                    _log.Info($"Auto-disconnect triggered for {t.Name}");
                    if (await DisconnectAsync(t.Id, automatic: true)) _autoConnected.Remove(t.Id);
                }
            }
        }
    }

    /// macOS userDidConnect / userDidDisconnect.
    private void UserConnected(Guid id)
    {
        _suppressed.Remove(id);
        _autoConnected.Remove(id);
    }

    private void UserDisconnected(Guid id)
    {
        _autoConnected.Remove(id);
        _suppressed.Add(id);
    }

    /// Wake: interfaces need a moment; then DDNS endpoints, gateway routes and the rules (waking on the same
    /// network sends no change notification, so this is the only place a rule would run).
    private async Task HandleWakeAsync()
    {
        if (IsShuttingDown) return;
        _log.Info("System woke from sleep");
        await Task.Delay(WakeSettle);
        if (IsShuttingDown || NeedsSetup) return;
        await RefreshNetworkStateAsync(evaluate: false);
        await CheckEndpointReResolutionAsync();
        await RefreshGatewayRoutesAsync();
        await EvaluateRulesWhenIdleAsync();
    }

    /// Called by the status poll: at most once a minute while tunnels are connected.
    private async Task CheckEndpointsIfDueAsync()
    {
        if (!HasActiveTunnels || Now - _endpointsCheckedAt < EndpointRecheckInterval) return;
        await CheckEndpointReResolutionAsync();
    }

    /// Port of checkEndpointReResolution: the service resolves Endpoint once, at connect; a peer behind DDNS whose
    /// address changed is unreachable until the tunnel restarts. A literal IP never triggers a restart.
    public async Task CheckEndpointReResolutionAsync()
    {
        if (IsShuttingDown || IsLoading || NeedsSetup) return;
        _endpointsCheckedAt = Now;
        var changed = new List<Tunnel>();
        foreach (var t in _tunnels.Where(t => t.IsActive && !IsBusy(t.Id)).ToList())
        {
            if (ConfiguredEndpoint(t) is not { } configured || Endpoint.TryParse(configured) is not { } wanted
                || t.Endpoint is not { } live || Endpoint.TryParse(live) is not { } current) continue;
            if (IPPrefixIsLiteral(wanted.Host)) continue;
            if (await _network.ResolveAsync(wanted.Host) is not { } fresh || fresh.ToString() == current.Host) continue;
            _log.Info($"Endpoint for {t.Name} changed: {current.Host} -> {fresh} (host: {wanted.Host})");
            changed.Add(t);
        }
        foreach (var t in changed) await RestartAsync(t);
    }

    /// Recorded at connect; for a personal tunnel connected before the app started, read from its config.
    private string? ConfiguredEndpoint(Tunnel t)
    {
        if (_configuredEndpoints.TryGetValue(t.Id, out var known)) return known;
        if (t.Scope != TunnelScope.Personal) return null;
        try { return WireGuardConfig.Parse(_configs.Read(t.ConfigPath)).PrimaryPeer?.Endpoint; }
        catch (Exception e) when (e is IOException or InvalidDataException) { return null; }
    }

    private static bool IPPrefixIsLiteral(string host) => Core.Net.IPPrefix.TryParseAddress(host, out _);

    /// Restarts one tunnel with its kill switch kept armed (it blocks during the gap), or a whole chain.
    /// Port of reconnectAfterWake, including its rule check before bringing the tunnel back.
    private async Task RestartAsync(Tunnel tunnel)
    {
        if (ActiveOrBusyChain(tunnel.Id) is { } chain)
        {
            if (await DisconnectHopChainAsync(chain.Id)) await ConnectHopChainAsync(chain.Id);
            return;
        }
        if (tunnel.Scope == TunnelScope.Managed && tunnel.ManagedPolicy?.UsersCanDisconnect == false) return;
        if (AliasOf(tunnel) is not { } alias || IsBusy(tunnel.Id)) return;
        _restarting = true;
        _disconnecting.Add(tunnel.Id);
        Notify();
        try
        {
            _log.Info($"Restarting {tunnel.Name}");
            if (tunnel.InventoryCommand is not null) await ProtectInventoryAsync(tunnel);
            await _service.StopAsync(tunnel.InterfaceName ?? alias);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            _log.Error($"Restart of {tunnel.Name} failed: {e.Message}");
            ReportFailure(tunnel, $"Unable to reconnect {tunnel.Name}: {e.Message}", automatic: true);
            return;
        }
        finally
        {
            _disconnecting.Remove(tunnel.Id);
            _restarting = false;
        }
        ClearRuntime(tunnel);
        if (MatchesDisconnect(tunnel) || (_autoConnected.Contains(tunnel.Id) && tunnel.AutoConnectRule.Connect.Enabled && !MatchesConnect(tunnel)))
        {
            _log.Info($"Network no longer permits automatic reconnection for {tunnel.Name}");
            FinalizeStopped(tunnel);
            await AfterDisconnectAsync(tunnel);
            _autoConnected.Remove(tunnel.Id);
            return;
        }
        await ConnectAsync(tunnel.Id, automatic: true);
    }

    /// The pre-VPN gateway changed: the service picked it when it added each route, so re-add the routes that
    /// use it. A chain keeps its route through the hop while its gateway route is replaced.
    public async Task RefreshGatewayRoutesAsync()
    {
        if (IsShuttingDown || NeedsSetup) return;
        foreach (var t in _tunnels.Where(t => t.IsActive && t.ExcludedRoutes.Count > 0).ToList())
        {
            await TryAsync(() => _service.SyncRoutesAsync(t.Id, []));
            await SyncExcludedRoutesAsync(t);
        }
        foreach (var chain in _hopChains.Where(IsChainActive).ToList())
        {
            if (Find(chain.HopTunnelID) is not { } hop || Find(chain.ExitTunnelID) is not { } exit) continue;
            if (await ChainRoutesAsync(hop, exit) is not { } routes) continue;
            await TryAsync(() => _service.SyncRoutesAsync(chain.Id, routes.Where(r => r.Tunnel is not null).ToList()));
            await TryAsync(() => _service.SyncRoutesAsync(chain.Id, routes));
        }
    }

    // MARK: - Editing rules

    /// Port of updateAutoConnectRule (personal) and updateManagedAutoConnectRule (administrators, through UAC).
    public async Task UpdateAutoConnectRuleAsync(Guid id, AutoConnectRule rule)
    {
        if (Find(id) is not { } tunnel) return;
        rule = Normalized(rule);
        if (tunnel.Scope == TunnelScope.Managed)
        {
            await SendManagedUpdateAsync(tunnel, tunnel.Name, null, tunnel.ManagedPolicy ?? new(), rule);
            _log.Info($"Auto-connect rule updated for shared tunnel {tunnel.Name}: enabled={rule.Enabled}");
        }
        else
        {
            tunnel.AutoConnectRule = rule;
            tunnel.UpdatedAt = Now;
            SavePersonalTunnels();
            _log.Info($"Auto-connect rule updated for {tunnel.Name}: enabled={rule.Enabled}");
            Notify();
        }
        await EvaluateRulesWhenIdleAsync();
    }

    /// Trimmed, unique SSIDs; subnets must be CIDRs (a bare address would never match, see AutoConnectNetworkMatch).
    private static AutoConnectRule Normalized(AutoConnectRule rule)
    {
        var copy = System.Text.Json.JsonSerializer.Deserialize<AutoConnectRule>(System.Text.Json.JsonSerializer.Serialize(rule, CoreJson.Options), CoreJson.Options)!;
        foreach (var half in new[] { copy.Connect, copy.Disconnect })
        {
            half.WifiSSIDs = half.WifiSSIDs.Select(s => s.Trim()).Where(s => s.Length is > 0 and <= 32).Distinct().ToList();
            half.EthernetSubnets = half.EthernetSubnets.Select(s => s.Trim()).Where(s => s.Length > 0).Distinct().ToList();
            if (half.EthernetSubnets.FirstOrDefault(s => !s.Contains('/') || !Core.Net.IPPrefix.IsValidCidr(s)) is { } bad)
                throw new InvalidOperationException($"\"{bad}\" is not a subnet in CIDR notation, e.g. 192.168.1.0/24.");
        }
        return copy;
    }
}

public sealed partial class TunnelManager
{
    /// Acts on a `wiretunnels://` link once the manager is ready (it may arrive while the app starts).
    public async Task HandleLinkAsync(AppLink link)
    {
        while (!IsInitialized) await Task.Delay(100);
        _log.Info($"Link: {link}");
        switch (link.Action)
        {
            case AppLinkAction.DisconnectAll:
                await StopAllActiveAsync();
                return;
            case AppLinkAction.Show:
                return;
        }
        if (_tunnels.FirstOrDefault(t => t.Name.Equals(link.Name, StringComparison.OrdinalIgnoreCase)) is not { } tunnel)
        {
            ErrorMessage = $"No tunnel named \"{link.Name}\".";
            return;
        }
        // Same rules as the dashboard toggle (chain legs refuse, shared policy applies), like the macOS intents.
        if (link.Action == AppLinkAction.Connect) { if (!tunnel.IsActive) await ConnectAsync(tunnel.Id); }
        else if (tunnel.IsActive) await DisconnectAsync(tunnel.Id);
    }
}
