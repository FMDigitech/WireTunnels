using WireTunnels.Contracts;
using WireTunnels.Core.Models;

namespace WireTunnels.Client.Tests;

/// Phase 6: On-Demand rules (port of the macOS handleNetworkChange cases), DDNS restarts, gateway routes, links.
public class AutomationTests : IDisposable
{
    private readonly Harness _h = new();
    private readonly FakeMonitor _monitor = new();
    private TunnelManager M => _h.Manager;

    public void Dispose() => _h.Dispose();

    private static PhysicalNetwork WiFi(string? ssid, params string[] gateways) => new(false, [], true, ssid, false, gateways);
    private static PhysicalNetwork Ethernet(string address) => new(true, [address], false, null, false, []);

    private async Task<Tunnel> Start(AutoConnectRule rule, PhysicalNetwork network)
    {
        await M.InitializeAsync();
        var tunnel = M.Create("office", Harness.Config());
        tunnel.AutoConnectRule = rule;
        _monitor.Current = network;
        await M.StartAutomationAsync(_monitor);
        return tunnel;
    }

    private async Task MoveTo(PhysicalNetwork network)
    {
        _monitor.Current = network;
        await M.RefreshNetworkStateAsync(evaluate: false);
        await M.EvaluateRulesAsync();
    }

    private static AutoConnectRule ConnectOnWiFi(params string[] ssids) =>
        new() { Connect = new() { Enabled = true, Interface = AutoConnectInterface.Wifi, WifiSSIDs = [.. ssids] } };

    [Fact]
    public async Task ConnectsOnAMatchingNetworkAndDisconnectsWhenLeavingIt()
    {
        var t = await Start(ConnectOnWiFi("Office"), WiFi("Home"));
        Assert.False(M.Find(t.Id)!.IsActive);
        await MoveTo(WiFi("Office"));
        Assert.True(M.Find(t.Id)!.IsActive);
        await MoveTo(WiFi("Cafe"));
        Assert.False(M.Find(t.Id)!.IsActive);
    }

    [Fact]
    public async Task AManualDisconnectHoldsUntilTheNetworkStopsMatching()
    {
        var t = await Start(ConnectOnWiFi("Office"), WiFi("Office"));
        Assert.True(M.Find(t.Id)!.IsActive);
        await M.DisconnectAsync(t.Id);
        await MoveTo(WiFi("Office"));
        Assert.False(M.Find(t.Id)!.IsActive);
        await MoveTo(WiFi("Cafe"));
        await MoveTo(WiFi("Office"));
        Assert.True(M.Find(t.Id)!.IsActive);
    }

    [Fact]
    public async Task ATunnelTheUserConnectedStaysUpOffTheRuleNetwork()
    {
        var t = await Start(ConnectOnWiFi("Office"), WiFi("Home"));
        await M.ConnectAsync(t.Id);
        await MoveTo(WiFi("Cafe"));
        Assert.True(M.Find(t.Id)!.IsActive);
    }

    [Fact]
    public async Task TheDisconnectHalfWinsAndEthernetSubnetsMatch()
    {
        var rule = new AutoConnectRule
        {
            Connect = new() { Enabled = true, Interface = AutoConnectInterface.Both },
            Disconnect = new() { Enabled = true, Interface = AutoConnectInterface.Ethernet, EthernetSubnets = ["192.168.10.0/24"] },
        };
        var t = await Start(rule, Ethernet("192.168.10.5"));
        Assert.False(M.Find(t.Id)!.IsActive);
        await MoveTo(Ethernet("10.1.2.3"));
        Assert.True(M.Find(t.Id)!.IsActive);
        await MoveTo(Ethernet("192.168.10.7"));
        Assert.False(M.Find(t.Id)!.IsActive);
    }

    [Fact]
    public async Task ARuleCannotConnectASharedTunnelUsersMayNotConnect()
    {
        await _h.Service.AdminAsync<Tunnel>(Ops.InstallManaged, new InstallManagedArgs { Name = "shared", Contents = Harness.Config() });
        _h.Service.Managed[0].AutoConnectRule = ConnectOnWiFi();
        _h.Service.Managed[0].ManagedPolicy = new ManagedTunnelPolicy { UsersCanConnect = false };
        await M.InitializeAsync();
        _monitor.Current = WiFi("Any");
        await M.StartAutomationAsync(_monitor);
        Assert.DoesNotContain(_h.Service.Calls, c => c.StartsWith("start shared"));
    }

    [Fact]
    public async Task ADdnsChangeRestartsOnlyThatTunnelAndKeepsItsKillSwitch()
    {
        _h.Network.Hosts["vpn.example"] = "203.0.113.5";
        await M.InitializeAsync();
        var ddns = M.Create("ddns", Harness.Config(endpoint: "vpn.example:51820"));
        var literal = M.Create("fixed", Harness.Config(endpoint: "203.0.113.9:51820"));
        await M.UpdateKillSwitchAsync(ddns.Id, true);
        _h.Service.LiveEndpoint = "203.0.113.5:51820";
        await M.ConnectAsync(ddns.Id);
        await M.ConnectAsync(literal.Id);
        await M.CheckEndpointReResolutionAsync();
        Assert.Equal(1, _h.Service.Calls.Count(c => c == "start ddns"));

        _h.Network.Hosts["vpn.example"] = "203.0.113.6";
        _h.Service.Calls.Clear();
        await M.CheckEndpointReResolutionAsync();
        Assert.Equal(["stop ddns", "start ddns"], _h.Service.Calls.Where(c => c.StartsWith("st")));
        Assert.DoesNotContain("killswitch ", _h.Service.Calls); // never disarmed in between
        Assert.True(M.Find(ddns.Id)!.IsActive);
        Assert.True(M.Find(literal.Id)!.IsActive);
    }

    [Fact]
    public async Task AGatewayChangeReAddsTheExclusionRoutes()
    {
        var t = await Start(new AutoConnectRule(), WiFi("Home", "192.168.1.1"));
        await M.ConnectAsync(t.Id);
        await M.UpdateExcludedRoutesAsync(t.Id, ["10.9.0.0/16"]);
        _h.Service.Calls.Clear();
        _monitor.Current = WiFi("Home", "192.168.50.1");
        await M.RefreshNetworkStateAsync(evaluate: false);
        await M.RefreshGatewayRoutesAsync();
        Assert.Equal(["routes ", "routes 10.9.0.0/16"], _h.Service.Calls.Where(c => c.StartsWith("routes")));

        _h.Service.FailRoutes = new ServiceException("down");
        await M.RefreshGatewayRoutesAsync();
        Assert.Contains("could not be applied", M.ErrorMessage);
    }

    [Fact]
    public async Task RulesAreSavedNormalizedAndBadSubnetsRejected()
    {
        var t = await Start(new AutoConnectRule(), WiFi("Home"));
        await M.UpdateAutoConnectRuleAsync(t.Id, ConnectOnWiFi(" Office ", "Office", ""));
        Assert.Equal(["Office"], M.Find(t.Id)!.AutoConnectRule.Connect.WifiSSIDs);
        var bad = new AutoConnectRule { Connect = new() { Enabled = true, EthernetSubnets = ["192.168.1.1"] } };
        await Assert.ThrowsAsync<InvalidOperationException>(() => M.UpdateAutoConnectRuleAsync(t.Id, bad));
    }

    [Fact]
    public async Task LinksConnectAndDisconnectSavedTunnelsByName()
    {
        await M.InitializeAsync();
        var t = M.Create("Office VPN", Harness.Config());
        await M.HandleLinkAsync(AppLink.Parse("wiretunnels://connect?name=office%20vpn")!);
        Assert.True(M.Find(t.Id)!.IsActive);
        await M.HandleLinkAsync(AppLink.Parse("wiretunnels://disconnect-all")!);
        Assert.False(M.Find(t.Id)!.IsActive);
        await M.HandleLinkAsync(new AppLink(AppLinkAction.Connect, "nope"));
        Assert.Equal("No tunnel named \"nope\".", M.ErrorMessage);
    }

    [Fact]
    public void TheSystemMonitorReadsThisPc()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var monitor = new SystemNetworkMonitor();
        var network = monitor.Read(new HashSet<string>());
        Assert.NotNull(network);
        Assert.True(network.IsOnEthernet || network.IsOnWiFi, "this PC has no physical network up");
        Assert.DoesNotContain(network.EthernetAddresses, a => a.StartsWith("169.254.") || a.StartsWith("fe80"));
    }

    [Theory]
    [InlineData("wiretunnels://connect?name=Office+VPN", AppLinkAction.Connect, "Office VPN")]
    [InlineData("WIRETUNNELS://Disconnect?name=a%26b", AppLinkAction.Disconnect, "a&b")]
    [InlineData("wiretunnels://show", AppLinkAction.Show, null)]
    public void LinksParse(string text, AppLinkAction action, string? name)
    {
        var link = AppLink.Parse(text)!;
        Assert.Equal(action, link.Action);
        Assert.Equal(name, link.Name);
        Assert.Equal(link, AppLink.Parse(link.ToString()));
    }

    [Theory]
    [InlineData("wiretunnels://connect")]
    [InlineData("wiretunnels://format?name=x")]
    [InlineData("https://connect?name=x")]
    [InlineData("not a link")]
    public void InvalidLinksAreIgnored(string text) => Assert.Null(AppLink.Parse(text));
}
