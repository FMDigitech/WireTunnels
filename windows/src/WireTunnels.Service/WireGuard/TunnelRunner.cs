using System.Net;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Net;
using WireTunnels.Service.Native;
using WireTunnels.Service.Network;

namespace WireTunnels.Service.WireGuard;

/// What the dispatcher needs from the tunnel engine; faked in tests.
internal interface ITunnelBackend
{
    /// `suppressDns` leaves the adapter's DNS alone (split DNS or a multi-hop hop leg).
    Task StartAsync(string alias, WireGuardConfig config, bool suppressDns, CancellationToken ct);
    void Stop(string alias);
    bool IsRunning(string alias);
    TunnelRuntimeStatus Status(string alias);
    /// The running adapter's LUID, or null.
    ulong? Luid(string alias);
    /// Replaces the AllowedIPs of one peer of a running tunnel (inventory).
    void SetPeerAllowedIPs(string alias, string peerPublicKey, IReadOnlyList<IPPrefix> allowed);
    IReadOnlySet<ulong> Luids { get; }
}

/// The Windows replacement of wg-quick: one wireguard-nt adapter per tunnel, configured in memory.
/// Closing an adapter handle removes the adapter with its addresses, routes and DNS, so a failed
/// start rolls back completely and a crashed service leaves nothing behind.
[SupportedOSPlatform("windows")]
internal sealed class TunnelRunner(IFirewall firewall, ILogger<TunnelRunner> log) : ITunnelBackend, IDisposable
{
    /// Marks our adapters; adapters of other WireGuard clients are never opened or touched.
    public const string TunnelType = "WireTunnels";
    private const uint DefaultMtu = 1420;

    private readonly Dictionary<string, WireGuardNative.AdapterHandle> _adapters = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DnsGuard> _dnsGuards = new(StringComparer.Ordinal);

    public bool IsRunning(string alias) => _adapters.ContainsKey(alias);

    public ulong? Luid(string alias) => _adapters.TryGetValue(alias, out var adapter) ? WireGuardNative.Luid(adapter) : null;

    public IReadOnlySet<ulong> Luids => _adapters.Values.Select(WireGuardNative.Luid).ToHashSet();

    public async Task StartAsync(string alias, WireGuardConfig config, bool suppressDns, CancellationToken ct)
    {
        var endpoints = new List<IPEndPoint?>();
        foreach (var peer in config.Peers)
            endpoints.Add(peer.Endpoint is { } text ? await ResolveAsync(Endpoint.TryParse(text)!, ct) : null);

        var adapter = WireGuardNative.Create(alias, TunnelType, AdapterGuid(alias));
        try
        {
            WireGuardNative.SetConfiguration(adapter, ConfigBlob.Build(config, endpoints));
            WireGuardNative.SetState(adapter, WireGuardNative.AdapterState.Up);
            var luid = WireGuardNative.Luid(adapter);

            foreach (var address in config.Address) IpHelper.AddAddress(luid, IPPrefix.Parse(address));
            var mtu = (uint)(config.Mtu ?? (int)DefaultMtu);
            IpHelper.ConfigureInterface(luid, ipv4: true, mtu);
            IpHelper.ConfigureInterface(luid, ipv4: false, mtu);
            // wireguard-nt excludes its own adapter when routing its encrypted packets, so a
            // default route here does not loop (the macOS loop guard is not needed). Verified on
            // Windows 11 with wireguard-nt 1.1 and AllowedIPs = 0.0.0.0/0.
            foreach (var route in config.Peers.SelectMany(p => p.AllowedIPs).Select(IPPrefix.Parse).Distinct())
                IpHelper.AddRoute(luid, route);

            var servers = suppressDns ? [] : WireGuardDns.Servers(config.Dns);
            if (servers.Count > 0) IpHelper.SetDns(luid, servers, WireGuardDns.SearchDomains(config.Dns));
            // A full tunnel with its own DNS: block port 53 elsewhere, or Windows also asks the LAN's servers.
            var allowed = config.Peers.SelectMany(p => p.AllowedIPs).ToList();
            if (servers.Count > 0 && (IPFamilyRouting.RoutesAll(IPFamily.IPv4, allowed) || IPFamilyRouting.RoutesAll(IPFamily.IPv6, allowed)))
            {
                _dnsGuards[alias] = new DnsGuard(servers.Select(s => IPPrefix.Parse(s).Address).ToList());
                firewall.SetDnsGuards([.. _dnsGuards.Values]);
            }
        }
        catch
        {
            adapter.Dispose();
            if (_dnsGuards.Remove(alias)) TryUpdateDnsGuards();
            throw;
        }
        _adapters[alias] = adapter;
        log.LogInformation("Tunnel {Alias} is up", alias);
    }

    public void Stop(string alias)
    {
        if (!_adapters.Remove(alias, out var adapter)) return;
        adapter.Dispose();
        if (_dnsGuards.Remove(alias)) TryUpdateDnsGuards();
        log.LogInformation("Tunnel {Alias} is down", alias);
    }

    public void SetPeerAllowedIPs(string alias, string peerPublicKey, IReadOnlyList<IPPrefix> allowed) =>
        WireGuardNative.SetConfiguration(_adapters[alias], ConfigBlob.PeerAllowedIPs(peerPublicKey, allowed));

    public TunnelRuntimeStatus Status(string alias) =>
        ConfigBlob.Read(alias, WireGuardNative.GetConfiguration(_adapters[alias]));

    /// Stopping must not fail because of the guard: the adapter is already gone either way.
    private void TryUpdateDnsGuards()
    {
        try { firewall.SetDnsGuards([.. _dnsGuards.Values]); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception) { log.LogError(e, "Unable to update the DNS leak guard"); }
    }

    public void Dispose()
    {
        foreach (var alias in _adapters.Keys.ToList()) Stop(alias);
    }

    /// Stable per alias, so Windows keeps one network profile per tunnel instead of a new one each connect.
    private static Guid AdapterGuid(string alias) =>
        new(SHA256.HashData(Encoding.UTF8.GetBytes("WireTunnels:" + alias)).AsSpan(0, 16));

    private static async Task<IPEndPoint> ResolveAsync(Endpoint endpoint, CancellationToken ct)
    {
        if (IPPrefix.TryParseAddress(endpoint.Host, out var ip)) return new IPEndPoint(ip, endpoint.Port);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var addresses = await Dns.GetHostAddressesAsync(endpoint.Host, timeout.Token);
        // Prefer IPv4 like wg(8) on most networks; fall back to whatever resolved.
        var chosen = addresses.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork) ?? addresses.FirstOrDefault()
            ?? throw new InvalidOperationException($"Endpoint {endpoint.Host} did not resolve");
        return new IPEndPoint(chosen, endpoint.Port);
    }
}
