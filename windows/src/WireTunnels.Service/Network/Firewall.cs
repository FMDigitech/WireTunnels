using System.Runtime.Versioning;
using WireTunnels.Service.Native;

namespace WireTunnels.Service.Network;

/// What the service needs from the firewall; faked in tests.
internal interface IFirewall
{
    /// Replaces the kill switch. Its filters are persistent: they keep blocking if the service crashes.
    void SetKillSwitch(IReadOnlyList<KillSwitchRule> rules);
    /// Replaces the DNS leak guards. Dynamic filters: they vanish with the service process, like the adapters.
    void SetDnsGuards(IReadOnlyList<DnsGuard> guards);
    /// Replaces the inventory protection. Persistent, and kept across reboots and service stops.
    void SetInventoryGuards(IReadOnlyList<InventoryGuard> guards);
}

[SupportedOSPlatform("windows")]
internal sealed class Firewall : IFirewall, IDisposable
{
    private readonly object _lock = new();
    private readonly ILogger<Firewall> _log;
    private IntPtr _persistent, _dynamic;

    public Firewall(ILogger<Firewall> log) => _log = log;

    private IntPtr Persistent
    {
        get
        {
            if (_persistent != IntPtr.Zero) return _persistent;
            _persistent = Wfp.Open(dynamic: false);
            Wfp.EnsureProviderAndSubLayer(_persistent);
            return _persistent;
        }
    }

    private IntPtr Dynamic
    {
        get
        {
            if (_dynamic != IntPtr.Zero) return _dynamic;
            _ = Persistent; // the sublayer must exist first
            return _dynamic = Wfp.Open(dynamic: true);
        }
    }

    public void SetKillSwitch(IReadOnlyList<KillSwitchRule> rules)
    {
        lock (_lock) Replace(Persistent, persistent: true, FirewallRules.KillSwitch(rules));
        _log.LogInformation("Kill switch {State} ({Count} tunnel(s))", rules.Count > 0 ? "armed" : "cleared", rules.Count);
    }

    public void SetDnsGuards(IReadOnlyList<DnsGuard> guards)
    {
        lock (_lock) Replace(Dynamic, persistent: false, FirewallRules.DnsGuards(guards));
    }

    public void SetInventoryGuards(IReadOnlyList<InventoryGuard> guards)
    {
        lock (_lock) Replace(Persistent, persistent: true, FirewallRules.Inventory(guards), Wfp.InventoryProviderKey);
    }

    private static void Replace(IntPtr engine, bool persistent, IReadOnlyList<WfpFilter> filters, Guid? provider = null) =>
        Wfp.Transaction(engine, () =>
        {
            var key = provider ?? Wfp.ProviderKey;
            foreach (var id in Wfp.OurFilters(engine, key, persistent)) Wfp.Delete(engine, id);
            foreach (var filter in filters) Wfp.Add(engine, filter, key, persistent);
        });

    public void Dispose()
    {
        lock (_lock)
        {
            if (_dynamic != IntPtr.Zero) Wfp.Close(_dynamic);
            if (_persistent != IntPtr.Zero) Wfp.Close(_persistent);
            _dynamic = _persistent = IntPtr.Zero;
        }
    }
}
