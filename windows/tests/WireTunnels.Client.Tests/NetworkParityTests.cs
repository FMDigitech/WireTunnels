using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;

namespace WireTunnels.Client.Tests;

/// Phase 4 behaviour of the TunnelManager, against the fake service (the macOS TunnelManager rules).
public class NetworkParityTests : IDisposable
{
    private readonly Harness _h = new();
    private TunnelManager M => _h.Manager;
    private FakeTunnelService S => _h.Service;

    public void Dispose() => _h.Dispose();

    private async Task<Tunnel> Ready(string name = "office", string? config = null)
    {
        await M.InitializeAsync();
        return M.Create(name, config ?? Harness.Config());
    }

    [Fact]
    public async Task KillSwitchArmsOnConnectAndDisarmsOnAnIntentionalDisconnect()
    {
        var tunnel = await Ready();
        await M.UpdateKillSwitchAsync(tunnel.Id, true);
        Assert.Empty(S.KillSwitch); // not connected: nothing to arm yet

        await M.ConnectAsync(tunnel.Id);
        var entry = Assert.Single(S.KillSwitch);
        Assert.Equal((tunnel.InterfaceName, "198.51.100.1", 51820), (entry.Name, entry.EndpointHost, entry.EndpointPort));
        Assert.True(M.IsKillSwitchArmed(tunnel.Id));

        await M.DisconnectAsync(tunnel.Id);
        Assert.Empty(S.KillSwitch);
        Assert.DoesNotContain(M.Warnings, w => w.Kind == TunnelWarningKind.KillSwitchBlocking);
    }

    [Fact]
    public async Task ALostTunnelKeepsBlockingUntilTheKillSwitchIsTurnedOff()
    {
        var tunnel = await Ready();
        await M.UpdateKillSwitchAsync(tunnel.Id, true);
        await M.ConnectAsync(tunnel.Id);

        S.Running.Clear(); // the adapter vanished (service restart)
        await M.RefreshStatusAsync();
        Assert.False(tunnel.IsActive);
        Assert.Single(S.KillSwitch);
        Assert.Contains(M.Warnings, w => w.Kind == TunnelWarningKind.KillSwitchBlocking);

        await M.UpdateKillSwitchAsync(tunnel.Id, false);
        Assert.Empty(S.KillSwitch);
        Assert.DoesNotContain(M.Warnings, w => w.Kind == TunnelWarningKind.KillSwitchBlocking);
    }

    [Fact]
    public async Task StartupClearsAStaleKillSwitchAndReArmsConnectedTunnels()
    {
        var tunnel = await Ready();
        await M.UpdateKillSwitchAsync(tunnel.Id, true);
        await M.ConnectAsync(tunnel.Id);
        S.Calls.Clear();

        _h.NewManager(); // the app restarts while the tunnel keeps running in the service
        await M.InitializeAsync();
        Assert.Equal("killswitch ", S.Calls.First(c => c.StartsWith("killswitch")));
        Assert.Single(S.KillSwitch);
    }

    [Fact]
    public async Task SplitDnsKeepsTheAdapterDnsOffAndSyncsOnlyActiveTunnels()
    {
        var tunnel = await Ready();
        await M.UpdateSplitDnsDomainsAsync(tunnel.Id, ["*.Corp.Example", "lan", "lan", "not a domain"]);
        Assert.Equal(["corp.example", "lan"], tunnel.SplitDNSDomains);
        Assert.Empty(S.SplitDns);

        await M.ConnectAsync(tunnel.Id);
        Assert.Contains(tunnel.InterfaceName, S.SuppressedDns);
        var entry = Assert.Single(S.SplitDns);
        Assert.Equal(["corp.example", "lan"], entry.Domains);
        Assert.Equal(["10.0.0.1"], entry.Servers);

        Assert.False(M.SplitDnsChangeNeedsReconnect(tunnel.Id, ["lan"]));
        Assert.True(M.SplitDnsChangeNeedsReconnect(tunnel.Id, []));
        await M.DisconnectAsync(tunnel.Id);
        Assert.Empty(S.SplitDns);
    }

    [Fact]
    public async Task ATunnelWithoutSplitDnsKeepsItsAdapterDns()
    {
        var tunnel = await Ready();
        await M.ConnectAsync(tunnel.Id);
        Assert.Empty(S.SuppressedDns);
        Assert.Empty(S.SplitDns);
    }

    [Fact]
    public async Task ExcludedRoutesGoThroughThePhysicalGatewayWhileConnected()
    {
        var tunnel = await Ready(config: Harness.Config(allowed: "0.0.0.0/0"));
        await M.UpdateExcludedRoutesAsync(tunnel.Id, ["10.0.5.0/24"]);
        Assert.False(S.Routes.ContainsKey(tunnel.Id)); // applied on connect

        await M.ConnectAsync(tunnel.Id);
        Assert.Equal([new RouteEntry { Cidr = "10.0.5.0/24" }], S.Routes[tunnel.Id]);

        await M.UpdateExcludedRoutesAsync(tunnel.Id, ["10.0.5.0/24", "192.168.50.0/24"]);
        Assert.Equal(2, S.Routes[tunnel.Id].Count);
        await M.UpdateExcludedRoutesAsync(tunnel.Id, ["10.0.5.1"]);
        Assert.Contains("CIDR", M.ErrorMessage);
        Assert.Equal(2, tunnel.ExcludedRoutes.Count);

        await M.DisconnectAsync(tunnel.Id);
        Assert.False(S.Routes.ContainsKey(tunnel.Id));
    }

    private async Task<(Tunnel Hop, Tunnel Exit, HopChain Chain)> Chain()
    {
        await M.InitializeAsync();
        var hop = M.Create("hop", Harness.Config(allowed: "0.0.0.0/0", endpoint: "198.51.100.1:51820"));
        var exit = M.Create("exit", Harness.Config(allowed: "0.0.0.0/0", endpoint: "exit.example:51820", address: "10.1.0.2/32", dns: "10.1.0.1"));
        M.AddHopChain(hop.Id, exit.Id);
        return (hop, exit, Assert.Single(M.HopChains));
    }

    [Fact]
    public async Task AHopChainRoutesTheExitThroughTheHop()
    {
        var (hop, exit, chain) = await Chain();
        S.Calls.Clear();
        await M.ConnectHopChainAsync(chain.Id);

        Assert.True(hop.IsActive && exit.IsActive);
        Assert.Contains(hop.InterfaceName, S.SuppressedDns); // the hop never sets DNS
        Assert.DoesNotContain(exit.InterfaceName, S.SuppressedDns);
        Assert.Equal([new RouteEntry { Cidr = "203.0.113.20/32", Tunnel = hop.InterfaceName }, new RouteEntry { Cidr = "198.51.100.1/32" }],
            S.Routes[chain.Id]);
        var order = S.Calls.Where(c => c.StartsWith("start") || c.StartsWith("routes")).ToList();
        Assert.Equal([$"start {hop.InterfaceName}", $"routes 203.0.113.20/32@{hop.InterfaceName},198.51.100.1/32", $"start {exit.InterfaceName}"], order);

        // Its legs cannot be stopped one by one while the chain is up.
        Assert.False(await M.DisconnectAsync(hop.Id));
        Assert.True(hop.IsActive);

        S.Calls.Clear();
        var (hopAlias, exitAlias) = (hop.InterfaceName, exit.InterfaceName);
        Assert.True(await M.DisconnectHopChainAsync(chain.Id));
        Assert.Equal([$"stop {exitAlias}", "routes ", $"stop {hopAlias}"],
            S.Calls.Where(c => c.StartsWith("stop") || c.StartsWith("routes")));
        Assert.False(hop.IsActive || exit.IsActive);
    }

    [Fact]
    public async Task AFailedExitRollsTheChainBack()
    {
        var (hop, exit, chain) = await Chain();
        _h.Network.Hosts.Clear(); // the exit endpoint no longer resolves
        await M.ConnectHopChainAsync(chain.Id);
        Assert.False(hop.IsActive || exit.IsActive);
        Assert.Contains("resolve", M.ErrorMessage);
        Assert.False(S.Routes.ContainsKey(chain.Id));
    }

    [Fact]
    public async Task ChainsAreValidatedSavedAndQuitStopsThemAsAUnit()
    {
        var (hop, exit, chain) = await Chain();
        var other = M.Create("other", Harness.Config());
        M.AddHopChain(hop.Id, other.Id);
        Assert.Contains("already part", M.ErrorMessage);
        Assert.Single(M.HopChains);
        Assert.True(File.Exists(_h.Paths.HopChainsFile));

        await M.ConnectHopChainAsync(chain.Id);
        Assert.True(await M.PrepareForQuitAsync());
        Assert.False(hop.IsActive || exit.IsActive);
        Assert.Empty(S.Routes);
        Assert.Contains("killswitch ", S.Calls);
        Assert.Contains("splitdns ", S.Calls);
    }

    [Fact]
    public async Task DeletingATunnelDropsItsChain()
    {
        var (hop, _, _) = await Chain();
        M.Delete(hop.Id);
        Assert.Empty(M.HopChains);
    }

    [Fact]
    public async Task AnIPv4OnlyFullTunnelOnAnIPv6NetworkWarnsAndTheFixAddsAPlaceholder()
    {
        _h.Network.Physical = ["192.168.1.10", "2001:db8:1::10"];
        var tunnel = await Ready(config: Harness.Config(allowed: "0.0.0.0/0"));
        await M.ConnectAsync(tunnel.Id);

        var leak = Assert.Single(M.LeaksOf(tunnel.Id));
        Assert.Equal(new IPFamilyLeak(IPFamily.IPv6, IPFamilyLeakReason.NotRouted), leak);
        Assert.Contains(M.Warnings, w => w.Kind == TunnelWarningKind.IpFamilyLeak);

        M.UpdateIpFamilyLeakAcknowledgement(tunnel.Id, true);
        Assert.DoesNotContain(M.Warnings, w => w.Kind == TunnelWarningKind.IpFamilyLeak);
        Assert.Single(M.LeaksOf(tunnel.Id)); // the facts stay
        M.UpdateIpFamilyLeakAcknowledgement(tunnel.Id, false);

        Assert.Null(M.FixUnavailableReason(tunnel.Id, leak));
        await M.FixIpFamilyLeakAsync(tunnel.Id, leak);
        var config = WireGuardConfig.Parse(M.ReadConfig(tunnel.Id));
        Assert.Contains("::/0", config.PrimaryPeer!.AllowedIPs);
        Assert.Contains(config.Address, a => a.StartsWith("fd"));
        Assert.True(tunnel.IsActive); // reconnected with the fix
        Assert.Empty(M.LeaksOf(tunnel.Id));
    }

    [Fact]
    public async Task AnArmedKillSwitchMeansNoLeak()
    {
        _h.Network.Physical = ["192.168.1.10", "2001:db8:1::10"];
        var tunnel = await Ready(config: Harness.Config(allowed: "0.0.0.0/0"));
        await M.UpdateKillSwitchAsync(tunnel.Id, true);
        await M.ConnectAsync(tunnel.Id);
        Assert.Empty(M.LeaksOf(tunnel.Id));
    }

    [Fact]
    public async Task ABypassedRouteIsReportedWithoutAFix()
    {
        _h.Network.Bypassed = [IPFamily.IPv4];
        var tunnel = await Ready(config: Harness.Config(allowed: "0.0.0.0/0"));
        await M.ConnectAsync(tunnel.Id);
        var leak = Assert.Single(M.LeaksOf(tunnel.Id));
        Assert.Equal(IPFamilyLeakReason.RouteBypassed, leak.Reason);
        Assert.Equal(IPFamilyLeakFix.UnavailableReason.RouteBypassed, M.FixUnavailableReason(tunnel.Id, leak));
    }
}
