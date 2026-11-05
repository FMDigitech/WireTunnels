using System.Net;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Net;
using WireTunnels.Service.Native;

namespace WireTunnels.Service.WireGuard;

/// What the dispatcher needs from the tunnel engine; faked in tests.
internal interface ITunnelBackend
{
    Task StartAsync(string alias, WireGuardConfig config, CancellationToken ct);
    void Stop(string alias);
    bool IsRunning(string alias);
    TunnelRuntimeStatus Status(string alias);
}

/// The Windows replacement of wg-quick: one wireguard-nt adapter per tunnel, configured in memory.
/// Closing an adapter handle removes the adapter with its addresses, routes and DNS, so a failed
/// start rolls back completely and a crashed service leaves nothing behind.
[SupportedOSPlatform("windows")]
internal sealed class TunnelRunner(ILogger<TunnelRunner> log) : ITunnelBackend, IDisposable
{
    /// Marks our adapters; adapters of other WireGuard clients are never opened or touched.
    public const string TunnelType = "WireTunnels";
    private const uint DefaultMtu = 1420;

    private readonly Dictionary<string, WireGuardNative.AdapterHandle> _adapters = new(StringComparer.Ordinal);

    public bool IsRunning(string alias) => _adapters.ContainsKey(alias);

    public async Task StartAsync(string alias, WireGuardConfig config, CancellationToken ct)
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
            // default route here does not loop (the macOS loop guard is not needed). Verify in the spike.
            foreach (var route in config.Peers.SelectMany(p => p.AllowedIPs).Select(IPPrefix.Parse).Distinct())
                IpHelper.AddRoute(luid, route);

            var servers = WireGuardDns.Servers(config.Dns);
            if (servers.Count > 0) IpHelper.SetDns(luid, servers, WireGuardDns.SearchDomains(config.Dns));
        }
        catch
        {
            adapter.Dispose();
            throw;
        }
        _adapters[alias] = adapter;
        log.LogInformation("Tunnel {Alias} is up", alias);
    }

    public void Stop(string alias)
    {
        if (!_adapters.Remove(alias, out var adapter)) return;
        adapter.Dispose();
        log.LogInformation("Tunnel {Alias} is down", alias);
    }

    public TunnelRuntimeStatus Status(string alias) =>
        ConfigBlob.Read(alias, WireGuardNative.GetConfiguration(_adapters[alias]));

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
