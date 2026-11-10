using System.Net;
using System.Runtime.Versioning;
using System.Text.Json;
using Microsoft.Win32;
using WireTunnels.Contracts;
using WireTunnels.Core.Net;
using WireTunnels.Service.Ipc;
using WireTunnels.Service.Native;
using WireTunnels.Service.WireGuard;

namespace WireTunnels.Service.Network;

/// A route the service added, with what is needed to remove it exactly.
internal sealed record InstalledRoute(string Cidr, ulong Luid, string? NextHop);

/// The routing table; faked in tests.
internal interface IRouteTable
{
    /// On-link through `tunnelLuid`, or through the physical default gateway when it is null.
    InstalledRoute Add(IPPrefix prefix, ulong? tunnelLuid, IReadOnlySet<ulong> ownAdapters);
    void Delete(InstalledRoute route);
}

/// State that outlives a service crash but must not outlive a reboot; faked in tests.
internal interface IJournal
{
    string? Load();
    void Save(string? json);
}

/// Kill switch, split DNS and extra routes, per Windows user (the macOS helper's syncKillSwitch,
/// syncSplitDNS and syncRoutes). Callers validate and serialize the calls (RequestDispatcher).
///
/// Recovery: adapters, their addresses, routes and DNS guard vanish with the service process. What lives
/// outside them is journaled in a volatile registry key, which Windows deletes at boot: after a crash
/// the kill switch keeps blocking and our gateway routes are removed; after a reboot nothing is restored.
internal sealed class NetworkPolicy(ITunnelBackend backend, IFirewall firewall, INrptStore nrpt, IRouteTable routes, IJournal journal,
    ILogger<NetworkPolicy> log)
{
    private sealed record Journaled(Dictionary<string, List<KillSwitchEntry>> KillSwitch, List<InstalledRoute> Routes);

    private Dictionary<string, List<KillSwitchEntry>> _killSwitch = new(StringComparer.Ordinal);
    private readonly Dictionary<(string Sid, Guid Owner), List<(RouteEntry Entry, InstalledRoute Installed)>> _routes = [];

    public bool KillSwitchArmed => _killSwitch.Count > 0;

    public void Recover()
    {
        SplitDns.Clear(nrpt);
        Journaled? saved = null;
        try { saved = journal.Load() is { } json ? JsonSerializer.Deserialize<Journaled>(json, Protocol.Json) : null; }
        catch (JsonException e) { log.LogWarning(e, "Ignoring an unreadable network journal"); }

        if (saved is null)
        {
            // Fresh boot (or first run): persistent filters left by the previous boot must not block it.
            firewall.SetKillSwitch([]);
            return;
        }
        foreach (var route in saved.Routes)
        {
            try { routes.Delete(route); }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException) { log.LogWarning(e, "Unable to remove stale route {Route}", route.Cidr); }
        }
        _killSwitch = new(saved.KillSwitch, StringComparer.Ordinal);
        ApplyKillSwitch();
        if (KillSwitchArmed) log.LogWarning("Restored the kill switch after a service restart: traffic stays blocked until its tunnels reconnect");
    }

    // MARK: kill switch

    public void SyncKillSwitch(string sid, IReadOnlyList<KillSwitchEntry> entries)
    {
        var previous = _killSwitch.GetValueOrDefault(sid);
        if (entries.Count == 0) _killSwitch.Remove(sid);
        else _killSwitch[sid] = [.. entries];
        try { ApplyKillSwitch(); }
        catch
        {
            if (previous is null) _killSwitch.Remove(sid);
            else _killSwitch[sid] = previous;
            throw;
        }
    }

    /// Re-resolves each armed tunnel's adapter: called after every start and stop.
    public void ApplyKillSwitch()
    {
        var rules = _killSwitch.Values.SelectMany(e => e).Select(e =>
            new KillSwitchRule(backend.IsRunning(e.Name) ? backend.Luid(e.Name) : null, IPAddress.Parse(e.EndpointHost), e.EndpointPort)).ToList();
        firewall.SetKillSwitch(rules);
        Save();
    }

    // MARK: split DNS

    public IReadOnlyList<string> SyncSplitDns(string sid, IReadOnlyDictionary<string, IReadOnlyList<string>> desired) =>
        SplitDns.Sync(nrpt, sid, desired);

    // MARK: routes

    /// Diffs against what this user installed for `owner` and adds or removes exactly the difference.
    public void SyncRoutes(string sid, Guid owner, IReadOnlyList<RouteEntry> desired)
    {
        var key = (sid, owner);
        var current = _routes.GetValueOrDefault(key) ?? [];
        try
        {
            foreach (var stale in current.Where(c => !desired.Contains(c.Entry)).ToList())
            {
                routes.Delete(stale.Installed);
                current.Remove(stale);
            }
            foreach (var entry in desired.Distinct().Where(d => current.All(c => c.Entry != d)))
            {
                ulong? luid = entry.Tunnel is { } alias
                    ? backend.Luid(alias) ?? throw new RequestException($"{alias} is not connected")
                    : null;
                current.Add((entry, routes.Add(IPPrefix.Parse(entry.Cidr), luid, backend.Luids)));
            }
        }
        finally
        {
            if (current.Count == 0) _routes.Remove(key);
            else _routes[key] = current;
            Save();
        }
    }

    /// The tunnel's adapter is gone, and with it every route on it: forget them so a later sync re-adds them.
    public void ForgetTunnel(string alias)
    {
        foreach (var key in _routes.Keys.ToList())
        {
            var kept = _routes[key].Where(r => r.Entry.Tunnel != alias).ToList();
            if (kept.Count == 0) _routes.Remove(key);
            else _routes[key] = kept;
        }
        Save();
    }

    /// The user logged off: drop their kill switch, split DNS rules and routes.
    public void ForgetUser(string sid)
    {
        foreach (var key in _routes.Keys.Where(k => k.Sid == sid).ToList())
            SyncRoutes(sid, key.Owner, []);
        SplitDns.Sync(nrpt, sid, new Dictionary<string, IReadOnlyList<string>>());
        if (_killSwitch.ContainsKey(sid)) SyncKillSwitch(sid, []);
    }

    /// A clean service stop (also at Windows shutdown) leaves nothing behind: the stop is deliberate.
    public void Shutdown()
    {
        foreach (var route in _routes.Values.SelectMany(r => r))
        {
            try { routes.Delete(route.Installed); }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException) { log.LogWarning(e, "Unable to remove route {Route}", route.Installed.Cidr); }
        }
        _routes.Clear();
        _killSwitch.Clear();
        try { firewall.SetKillSwitch([]); }
        finally
        {
            SplitDns.Clear(nrpt);
            journal.Save(null);
        }
    }

    private void Save()
    {
        var installed = _routes.Values.SelectMany(r => r).Select(r => r.Installed).ToList();
        journal.Save(_killSwitch.Count == 0 && installed.Count == 0
            ? null
            : JsonSerializer.Serialize(new Journaled(_killSwitch, installed), Protocol.Json));
    }
}

[SupportedOSPlatform("windows")]
internal sealed class WindowsRouteTable : IRouteTable
{
    public InstalledRoute Add(IPPrefix prefix, ulong? tunnelLuid, IReadOnlySet<ulong> ownAdapters)
    {
        if (tunnelLuid is { } luid)
        {
            IpHelper.AddRoute(luid, prefix);
            return new InstalledRoute(prefix.ToString(), luid, null);
        }
        var gateway = IpHelper.PhysicalDefaultRoute(prefix.IsIPv4, ownAdapters)
            ?? throw new RequestException($"No {(prefix.IsIPv4 ? "IPv4" : "IPv6")} network outside the tunnels to route {prefix} through");
        IpHelper.AddRoute(gateway.Luid, prefix, gateway.NextHop);
        return new InstalledRoute(prefix.ToString(), gateway.Luid, gateway.NextHop.ToString());
    }

    public void Delete(InstalledRoute route) =>
        IpHelper.DeleteRoute(route.Luid, IPPrefix.Parse(route.Cidr), route.NextHop is { } hop ? IPAddress.Parse(hop) : null);
}

/// HKLM\SOFTWARE\WireTunnels\Runtime: a volatile key, gone after a reboot; only administrators can write it.
[SupportedOSPlatform("windows")]
internal sealed class VolatileRegistryJournal : IJournal
{
    private const string Parent = @"SOFTWARE\WireTunnels", Child = "Runtime", Value = "NetworkState";

    public string? Load()
    {
        using var key = Registry.LocalMachine.OpenSubKey($@"{Parent}\{Child}");
        return key?.GetValue(Value) as string;
    }

    public void Save(string? json)
    {
        using var parent = Registry.LocalMachine.CreateSubKey(Parent, writable: true);
        using var key = parent.CreateSubKey(Child, writable: true, RegistryOptions.Volatile);
        if (json is null) key.DeleteValue(Value, throwOnMissingValue: false);
        else key.SetValue(Value, json, RegistryValueKind.String);
    }
}

/// Recovers network state at service start and restores it on a clean stop
/// (hosted services stop in reverse order, so the pipe is already closed then).
internal sealed class NetworkLifetime(NetworkPolicy policy, InventoryPolicy inventory, ILogger<NetworkLifetime> log) : IHostedService
{
    public Task StartAsync(CancellationToken cancellationToken)
    {
        policy.Recover();
        // Inventory protection is kept on a clean stop too: it is lifted only by removing the policy.
        try { inventory.Restore(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or System.ComponentModel.Win32Exception)
        {
            log.LogError(e, "Unable to restore inventory protection; its persistent firewall filters stay as they were");
        }
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        try { policy.Shutdown(); }
        catch (Exception e) { log.LogError(e, "Unable to restore network settings on shutdown"); }
        return Task.CompletedTask;
    }
}
