using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;

namespace WireTunnels.Client;

/// Network parity (phase 4), ported from TunnelManager.swift: kill switch, split DNS, split-tunnel
/// exclusions, multi-hop chains and IPv4/IPv6 leak detection. The service applies the state; this
/// side decides what the desired state is and sends it whole after every relevant change.
public sealed partial class TunnelManager
{
    private readonly HashSet<Guid> _killSwitchArmed = [];
    private readonly Dictionary<Guid, KillSwitchEntry> _killSwitchEntries = [];
    private readonly Dictionary<Guid, TunnelRouting> _runningRouting = [];
    private readonly HashSet<Guid> _connectingChains = [];
    private List<HopChain> _hopChains = [];
    private string? _lastSplitDns;
    private IReadOnlySet<IPFamily> _physicalFamilies = new HashSet<IPFamily>();
    private IReadOnlySet<IPFamily> _routeBypassed = new HashSet<IPFamily>();
    private IReadOnlyDictionary<Guid, IReadOnlyList<IPFamilyLeak>> _leaks = new Dictionary<Guid, IReadOnlyList<IPFamilyLeak>>();

    public IReadOnlyList<HopChain> HopChains => _hopChains;
    public bool IsKillSwitchArmed(Guid id) => _killSwitchArmed.Contains(id);
    public bool IsChainBusy(Guid chainId) => _connectingChains.Contains(chainId);
    /// Every leak of a connected tunnel, acknowledged or not (for its route label and the fix).
    public IReadOnlyList<IPFamilyLeak> LeaksOf(Guid id) => _leaks.GetValueOrDefault(id) ?? [];

    private void LoadHopChains()
    {
        if (_hopChainStore is null) return;
        try
        {
            _hopChains = _hopChainStore.Load();
            if (_hopChainStore.RecoveryWarning is { } warning) ReportStorageIssue(warning);
        }
        catch (IOException e) { ReportStorageIssue(e.Message); }
    }

    /// Startup, like macOS: drop any kill switch left from an earlier run, re-arm tunnels still connected, push split DNS.
    private async Task RestoreNetworkStateAsync()
    {
        _killSwitchArmed.Clear();
        _killSwitchEntries.Clear();
        await SyncKillSwitchStateAsync();
        foreach (var tunnel in _tunnels.Where(t => t.IsActive && t.IsKillSwitchEnabled).ToList()) await ArmKillSwitchAsync(tunnel);
        await SyncSplitDnsStateAsync(force: true);
        await RestoreInventoryAsync();
        await CheckIpFamilyRoutesAsync();
    }

    /// Everything a successful connect adds on top of the adapter (macOS connectTunnel, after startTunnel).
    private async Task AfterConnectAsync(Guid id)
    {
        if (Find(id) is { IsActive: true, IsKillSwitchEnabled: true } armed) await ArmKillSwitchAsync(armed);
        if (Find(id) is { IsActive: true, ExcludedRoutes.Count: > 0 } excluded) await SyncExcludedRoutesAsync(excluded);
        await CheckIpFamilyRoutesAsync();
        await SyncSplitDnsStateAsync();
        if (Find(id) is { IsActive: true, InventoryCommand: not null } inventory) await OpenInventoryAsync(inventory);
    }

    /// An intentional stop: disarm, drop its exclusions, update split DNS (macOS finalizeStoppedTunnel).
    private async Task AfterDisconnectAsync(Tunnel tunnel)
    {
        if (_killSwitchArmed.Contains(tunnel.Id)) await DisarmKillSwitchAsync(tunnel);
        if (tunnel.ExcludedRoutes.Count > 0) await TryAsync(() => _service.SyncRoutesAsync(tunnel.Id, []));
        await SyncSplitDnsStateAsync();
        await CheckIpFamilyRoutesAsync();
    }

    // MARK: - Kill switch

    public async Task UpdateKillSwitchAsync(Guid id, bool enabled)
    {
        if (Find(id) is not { Scope: TunnelScope.Personal } tunnel) return;
        tunnel.KillSwitchEnabled = enabled;
        tunnel.UpdatedAt = Now;
        SavePersonalTunnels();
        _log.Info($"Kill switch updated for {tunnel.Name}: enabled={enabled}");
        Notify();
        // Arms right away when connected; disarming always applies (it also releases a tunnel stuck blocking).
        if (!enabled) await DisarmKillSwitchAsync(tunnel);
        else if (tunnel.IsActive) await ArmKillSwitchAsync(tunnel);
    }

    private async Task ArmKillSwitchAsync(Tunnel tunnel)
    {
        if (IsShuttingDown) return;
        var endpoint = tunnel.Endpoint is { } text ? Endpoint.TryParse(text) : null;
        var address = endpoint is null ? null : await _network.ResolveAsync(endpoint.Host);
        if (endpoint is null || address is null || tunnel.InterfaceName is not { } alias)
        {
            _log.Warning($"Kill switch could not determine tunnel endpoint for {tunnel.Name}; leaving traffic unprotected");
            if (_notificationsEnabled()) _notifier.Failed(tunnel.Name, "Kill switch could not be enabled: tunnel endpoint is unknown");
            return;
        }
        _killSwitchEntries[tunnel.Id] = new KillSwitchEntry { Name = alias, EndpointHost = address.ToString(), EndpointPort = endpoint.Port };
        _killSwitchArmed.Add(tunnel.Id);
        await SyncKillSwitchStateAsync();
        _log.Info($"Kill switch armed for {tunnel.Name}");
    }

    private async Task DisarmKillSwitchAsync(Tunnel tunnel)
    {
        if (!_killSwitchArmed.Remove(tunnel.Id)) return;
        _killSwitchEntries.Remove(tunnel.Id);
        await SyncKillSwitchStateAsync();
        _log.Info($"Kill switch disarmed for {tunnel.Name}");
    }

    private async Task SyncKillSwitchStateAsync()
    {
        if (IsShuttingDown) return;
        var entries = _killSwitchArmed.Select(id => _killSwitchEntries.GetValueOrDefault(id)).OfType<KillSwitchEntry>().ToList();
        try { await _service.SyncKillSwitchAsync(entries); }
        catch (Exception e) when (IsServiceFailure(e))
        {
            _log.Error($"Failed to sync kill switch rules: {e.Message}");
            ErrorMessage = $"Kill switch could not be updated: {e.Message}";
        }
        UpdateWarnings();
        Notify();
    }

    // MARK: - Split DNS

    private static List<string> NormalizedUniqueDomains(IEnumerable<string> domains) =>
        domains.Select(WireGuardDns.NormalizedDomain).OfType<string>().Distinct().ToList();

    /// Turning split DNS on or off for a connected tunnel changes whether its adapter got DNS: only a reconnect applies that.
    public bool SplitDnsChangeNeedsReconnect(Guid id, IEnumerable<string> newDomains) =>
        Find(id) is { IsActive: true } live && live.EffectiveSplitDNSDomains.Count == 0 != (NormalizedUniqueDomains(newDomains).Count == 0);

    public async Task UpdateSplitDnsDomainsAsync(Guid id, IEnumerable<string> domains, bool reconnect = false)
    {
        if (Find(id) is not { Scope: TunnelScope.Personal } tunnel) return;
        tunnel.SplitDNSDomains = NormalizedUniqueDomains(domains);
        tunnel.UpdatedAt = Now;
        SavePersonalTunnels();
        Notify();
        if (reconnect && tunnel.IsActive)
        {
            if (await DisconnectAsync(id)) await ConnectAsync(id);
        }
        else await SyncSplitDnsStateAsync();
    }

    /// Every active tunnel with split DNS domains and at least one DNS server.
    private async Task SyncSplitDnsStateAsync(bool force = false)
    {
        if (IsShuttingDown) return;
        var entries = _tunnels.Where(t => t.IsActive && t.EffectiveSplitDNSDomains.Count > 0).Select(t => new SplitDnsEntry
        {
            OwnerId = t.Id.ToString(),
            Domains = [.. t.EffectiveSplitDNSDomains],
            Servers = [.. WireGuardDns.Servers(_runningRouting.GetValueOrDefault(t.Id)?.Dns ?? t.Dns)],
        }).Where(e => e.Servers.Count > 0).ToList();
        var key = JsonSerializer.Serialize(entries);
        if (!force && key == _lastSplitDns) return;
        _lastSplitDns = key; // also on failure: retry on the next state change, not every poll
        try { await _service.SyncSplitDnsAsync(entries); }
        catch (Exception e) when (IsServiceFailure(e))
        {
            _log.Error($"Failed to sync split DNS: {e.Message}");
            if (force || entries.Count > 0) ErrorMessage = $"Split DNS could not be applied: {e.Message}";
        }
    }

    // MARK: - Split tunnel exclusions

    /// Saves the excluded CIDRs and, when connected, re-syncs the routes at once.
    public async Task UpdateExcludedRoutesAsync(Guid id, IEnumerable<string> routes)
    {
        if (IsBusy(id))
        {
            ErrorMessage = "Wait for the tunnel operation to finish before changing bypass routes.";
            return;
        }
        if (Find(id) is not { Scope: TunnelScope.Personal } tunnel) return;
        var list = routes.Select(r => r.Trim()).Where(r => r.Length > 0).Distinct().ToList();
        if (tunnel.InventoryCommand is not null && list.Count > 0)
        {
            ErrorMessage = "Inventory-protected tunnels cannot use bypass routes.";
            return;
        }
        if (list.FirstOrDefault(r => !IPPrefix.IsValidCidr(r)) is { } invalid)
        {
            ErrorMessage = $"\"{invalid}\" is not a network in CIDR notation, e.g. 10.0.5.0/24.";
            return;
        }
        tunnel.ExcludedRoutes = list;
        tunnel.UpdatedAt = Now;
        SavePersonalTunnels();
        Notify();
        if (tunnel.IsActive) await SyncExcludedRoutesAsync(tunnel);
    }

    /// Routes each excluded CIDR through the pre-VPN gateway, which the service finds itself.
    private async Task SyncExcludedRoutesAsync(Tunnel tunnel)
    {
        if (IsShuttingDown) return;
        try { await _service.SyncRoutesAsync(tunnel.Id, tunnel.ExcludedRoutes.Select(c => new RouteEntry { Cidr = c }).ToList()); }
        catch (Exception e) when (IsServiceFailure(e))
        {
            _log.Warning($"Failed to sync route exclusions for {tunnel.Name}: {e.Message}");
            ErrorMessage = $"Bypass routes for {tunnel.Name} could not be applied: {e.Message}";
        }
    }

    // MARK: - Multi-hop chains

    /// The enabled chain the tunnel belongs to, as hop or exit.
    public HopChain? ChainOf(Guid tunnelId) =>
        _hopChains.FirstOrDefault(c => c.IsEnabled && (c.HopTunnelID == tunnelId || c.ExitTunnelID == tunnelId));

    /// The chain only when it is fully up or mid-operation: a chain with one leg connected individually
    /// must not trap that leg (macOS activeOrBusyChain).
    private HopChain? ActiveOrBusyChain(Guid tunnelId)
    {
        if (ChainOf(tunnelId) is not { } chain) return null;
        if (_connectingChains.Contains(chain.Id)) return chain;
        return Find(chain.HopTunnelID)?.IsActive == true && Find(chain.ExitTunnelID)?.IsActive == true ? chain : null;
    }

    public bool IsChainActive(HopChain chain) =>
        Find(chain.HopTunnelID)?.IsActive == true && Find(chain.ExitTunnelID)?.IsActive == true;

    private string? ChainConflict(Guid tunnelId) =>
        ActiveOrBusyChain(tunnelId) is { } chain && !_connectingChains.Contains(chain.Id)
            ? $"{Find(tunnelId)?.Name} is part of a multi-hop chain; connect or disconnect the chain instead."
            : null;

    public void AddHopChain(Guid hopTunnelId, Guid exitTunnelId)
    {
        if (IsBusy(hopTunnelId) || IsBusy(exitTunnelId))
        {
            ErrorMessage = "Wait for the tunnel operations to finish before adding a hop chain.";
            return;
        }
        if (hopTunnelId == exitTunnelId || Find(hopTunnelId) is not { Scope: TunnelScope.Personal } || Find(exitTunnelId) is not { Scope: TunnelScope.Personal }) return;
        if (Find(hopTunnelId)?.InventoryCommand is not null || Find(exitTunnelId)?.InventoryCommand is not null)
        {
            ErrorMessage = "Inventory protection cannot be combined with hop chains.";
            return;
        }
        if (ChainOf(hopTunnelId) is not null || ChainOf(exitTunnelId) is not null)
        {
            ErrorMessage = "One of these tunnels is already part of another multi-hop chain.";
            return;
        }
        SaveHopChains([.. _hopChains, new HopChain { HopTunnelID = hopTunnelId, ExitTunnelID = exitTunnelId, CreatedAt = Now }]);
    }

    public void RemoveHopChain(Guid chainId)
    {
        if (_hopChains.FirstOrDefault(c => c.Id == chainId) is not { } chain) return;
        if (IsChainActive(chain) || _connectingChains.Contains(chainId))
        {
            ErrorMessage = "Disconnect the chain before removing it.";
            return;
        }
        SaveHopChains(_hopChains.Where(c => c.Id != chainId).ToList());
    }

    private void SaveHopChains(List<HopChain> chains)
    {
        try { _hopChainStore?.Save(chains); }
        catch (IOException e)
        {
            ReportStorageIssue($"Unable to save multi-hop chains: {e.Message}");
            return;
        }
        _hopChains = chains;
        Notify();
    }

    /// Routes that carry the exit tunnel's WireGuard packets inside the hop tunnel. The hop's own packets get a
    /// host route through the physical gateway: wireguard-nt only skips its own adapter, so without it the hop's
    /// packets would follow the exit's default route back into the exit tunnel.
    private async Task<List<RouteEntry>?> ChainRoutesAsync(Tunnel hop, Tunnel exit)
    {
        static string Host(IPAddress ip) => $"{ip}/{(ip.AddressFamily == AddressFamily.InterNetwork ? 32 : 128)}";
        var exitEndpoint = exit.Endpoint is { } e ? Endpoint.TryParse(e) : null;
        var hopEndpoint = hop.Endpoint is { } h ? Endpoint.TryParse(h) : null;
        var exitAddress = exitEndpoint is null ? null : await _network.ResolveAsync(exitEndpoint.Host);
        var hopAddress = hopEndpoint is null ? null : await _network.ResolveAsync(hopEndpoint.Host);
        if (exitAddress is null || hop.InterfaceName is not { } hopAlias) return null;
        List<RouteEntry> routes = [new RouteEntry { Cidr = Host(exitAddress), Tunnel = hopAlias }];
        if (hopAddress is not null) routes.Add(new RouteEntry { Cidr = Host(hopAddress) });
        return routes;
    }

    /// Connects the hop, routes the exit's WireGuard traffic through it, then connects the exit, so the exit
    /// server sees the hop's address. Rolls back everything it started on any failure.
    public async Task ConnectHopChainAsync(Guid chainId)
    {
        if (_hopChains.FirstOrDefault(c => c.Id == chainId) is not { } chain) return;
        if (!CanConnectTunnels)
        {
            if (!IsShuttingDown) ErrorMessage = ConnectionUnavailableReason;
            return;
        }
        if (_connectingChains.Contains(chainId)) return;
        if (Find(chain.HopTunnelID) is not { } hop || Find(chain.ExitTunnelID) is not { } exit)
        {
            ErrorMessage = "This multi-hop chain refers to a tunnel that no longer exists.";
            return;
        }
        if (hop.IsActive || exit.IsActive)
        {
            ErrorMessage = $"Disconnect {hop.Name} and {exit.Name} individually before connecting them as a chain.";
            return;
        }

        _connectingChains.Add(chainId);
        Notify();
        try
        {
            _log.Info($"Connecting hop chain: {hop.Name} -> {exit.Name}");
            await ConnectAsync(hop.Id, suppressDns: true);
            if (Find(hop.Id) is not { IsActive: true } liveHop)
            {
                ErrorMessage = $"Failed to connect hop tunnel {hop.Name}; multi-hop chain aborted.";
                return;
            }
            if (IsShuttingDown)
            {
                await DisconnectAsync(hop.Id);
                return;
            }
            if (await ChainRoutesAsync(liveHop, exit) is not { } routes)
            {
                ErrorMessage = $"Could not resolve {exit.Name}'s endpoint address; multi-hop chain aborted.";
                await DisconnectAsync(hop.Id);
                return;
            }
            try { await _service.SyncRoutesAsync(chainId, routes); }
            catch (Exception e) when (IsServiceFailure(e))
            {
                ErrorMessage = $"Failed to route {exit.Name} through {hop.Name}: {e.Message}";
                await TryAsync(() => _service.SyncRoutesAsync(chainId, []));
                await DisconnectAsync(hop.Id);
                return;
            }
            await ConnectAsync(exit.Id);
            if (Find(exit.Id)?.IsActive != true)
            {
                ErrorMessage = $"Failed to connect exit tunnel {exit.Name}; rolling back multi-hop chain.";
                await TryAsync(() => _service.SyncRoutesAsync(chainId, []));
                await DisconnectAsync(hop.Id);
                return;
            }
            _log.Info($"Hop chain connected: {hop.Name} -> {exit.Name}");
        }
        finally
        {
            _connectingChains.Remove(chainId);
            Notify();
        }
    }

    /// Exit down, routes removed, then hop down: the exit never falls back to a route that is already gone.
    public async Task<bool> DisconnectHopChainAsync(Guid chainId)
    {
        if (_hopChains.FirstOrDefault(c => c.Id == chainId) is not { } chain || !_connectingChains.Add(chainId)) return false;
        Notify();
        try
        {
            if (Find(chain.ExitTunnelID) is { IsActive: true } exit && !await DisconnectAsync(exit.Id)) return false;
            try { await _service.SyncRoutesAsync(chainId, []); }
            catch (Exception e) when (IsServiceFailure(e))
            {
                ErrorMessage = $"Unable to remove the multi-hop route: {e.Message}";
                return false;
            }
            if (Find(chain.HopTunnelID) is { IsActive: true } hop && !await DisconnectAsync(hop.Id)) return false;
            _log.Info($"Hop chain disconnected: {chain.HopTunnelID} -> {chain.ExitTunnelID}");
            return true;
        }
        finally
        {
            _connectingChains.Remove(chainId);
            Notify();
        }
    }

    // MARK: - IPv4 / IPv6 leaks

    public void UpdateIpFamilyLeakAcknowledgement(Guid id, bool acknowledged)
    {
        if (Find(id) is not { Scope: TunnelScope.Personal } tunnel) return;
        tunnel.IpFamilyLeakWarningAcknowledged = acknowledged;
        tunnel.UpdatedAt = Now;
        SavePersonalTunnels();
        UpdateWarnings();
        Notify();
    }

    public IPFamilyLeakFix.UnavailableReason? FixUnavailableReason(Guid id, IPFamilyLeak leak)
    {
        if (Find(id) is not { } tunnel) return IPFamilyLeakFix.UnavailableReason.Busy;
        var chainBusy = ChainOf(id) is { } chain && _connectingChains.Contains(chain.Id);
        return IPFamilyLeakFix.Unavailable(leak, _runningRouting.GetValueOrDefault(id)?.Dns ?? tunnel.Dns,
            tunnel.Scope == TunnelScope.Managed, tunnel.InventoryCommand is not null, IsBusy(id) || chainBusy);
    }

    /// Adds a placeholder address so the leaking family goes into the tunnel and stops there, then reconnects.
    public async Task FixIpFamilyLeakAsync(Guid id, IPFamilyLeak leak)
    {
        if (Find(id) is not { } live || FixUnavailableReason(id, leak) is not null) return;
        var family = leak.Family;
        try
        {
            var contents = ReadConfig(id);
            var fixedConfig = IPFamilyLeakFix.Apply(contents, family, IPFamilyLeakFix.PlaceholderAddress(family, Random.Shared));
            if (fixedConfig != contents)
            {
                Update(id, live.Name, fixedConfig);
                _log.Info($"Added placeholder {family.DisplayName()} address to {live.Name}");
            }
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or InvalidDataException or ConfigValidationException
            or ConfigStorageException or System.Security.Cryptography.CryptographicException)
        {
            var message = $"Could not disable {family.DisplayName()} for {live.Name}: {e.Message}";
            _log.Error(message);
            ErrorMessage = message;
            return;
        }
        if (!live.IsActive) return;
        if (ActiveOrBusyChain(id) is { } chain)
        {
            if (await DisconnectHopChainAsync(chain.Id)) await ConnectHopChainAsync(chain.Id);
        }
        else if (await DisconnectAsync(id, automatic: true)) await ConnectAsync(id, automatic: true);
    }

    /// Asks the routing table where public traffic of each fully routed family goes, then refreshes warnings.
    public async Task CheckIpFamilyRoutesAsync()
    {
        var active = _tunnels.Where(t => t.IsActive).ToList();
        var adapters = active.Select(t => t.InterfaceName).OfType<string>().ToHashSet(StringComparer.OrdinalIgnoreCase);
        var families = Enum.GetValues<IPFamily>().Where(f => active.Any(t =>
        {
            var routing = RoutingOf(t);
            return IPFamilyRouting.RoutesAll(f, routing.AllowedIPs) && IPFamilyRouting.HasAddress(f, routing.Address);
        })).ToHashSet();
        try
        {
            (_physicalFamilies, _routeBypassed) = await Task.Run(() => (
                IPFamilyRouting.InternetFamilies(_network.PhysicalAddresses(adapters)),
                adapters.Count < active.Count ? new HashSet<IPFamily>() : _network.BypassedFamilies(families, adapters)));
        }
        catch (Exception e) when (e is System.Net.NetworkInformation.NetworkInformationException or InvalidOperationException)
        {
            _log.Warning($"Unable to inspect the network for IP family leaks: {e.Message}");
        }
        UpdateWarnings();
        Notify();
    }

    private TunnelRouting RoutingOf(Tunnel t) =>
        _runningRouting.GetValueOrDefault(t.Id) ?? new TunnelRouting(t.Address ?? [], t.AllowedIPs, t.Dns);

    private IReadOnlyDictionary<Guid, IReadOnlyList<IPFamilyLeak>> CurrentLeakWarnings()
    {
        var active = _tunnels.Where(t => t.IsActive).ToList();
        foreach (var id in _runningRouting.Keys.Where(id => active.All(t => t.Id != id)).ToList()) _runningRouting.Remove(id);
        var inputs = active.Select(t => new IPFamilyLeakInput(t.Id, RoutingOf(t), t.Scope == TunnelScope.Personal && t.IpFamilyLeakWarningAcknowledged)).ToList();
        _leaks = IPFamilyLeakDetector.Leaks(inputs, _physicalFamilies, _routeBypassed, active.Any(t => _killSwitchArmed.Contains(t.Id)));
        return IPFamilyLeakDetector.Warnings(_leaks, inputs);
    }

    // MARK: - Helpers

    private static bool IsServiceFailure(Exception e) =>
        e is ServiceException or IOException or TimeoutException or UnauthorizedAccessException;

    private async Task TryAsync(Func<Task> call)
    {
        try { await call(); }
        catch (Exception e) when (IsServiceFailure(e)) { _log.Warning(e.Message); }
    }

    /// Quit: release the kill switch, split DNS and every route this app installed (macOS restoreNetworkSettingsForShutdown).
    private async Task<bool> RestoreNetworkForShutdownAsync()
    {
        if (SetupState != SetupState.Ready) return !HasActiveTunnels;
        try
        {
            await _service.SyncKillSwitchAsync([]);
            _killSwitchArmed.Clear();
            _killSwitchEntries.Clear();
            await _service.SyncSplitDnsAsync([]);
            _lastSplitDns = null;
            foreach (var owner in _tunnels.Where(t => t.ExcludedRoutes.Count > 0).Select(t => t.Id).Concat(_hopChains.Select(c => c.Id)).Distinct())
                await _service.SyncRoutesAsync(owner, []);
            _log.Info("Quit: all tunnels stopped and network settings restored");
            return true;
        }
        catch (Exception e) when (IsServiceFailure(e))
        {
            _log.Error($"Quit cleanup failed: {e.Message}");
            ErrorMessage = $"Unable to finish quit cleanup: {e.Message}";
            return false;
        }
    }
}
