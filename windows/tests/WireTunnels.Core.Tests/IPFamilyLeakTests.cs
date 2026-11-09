using System.Text.RegularExpressions;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;

namespace WireTunnels.Core.Tests;

/// Port of Tests/IPFamilyLeakDetectorTests.swift.
public class IPFamilyLeakDetectorTests
{
    private static readonly string[] All = ["0.0.0.0/0", "::/0"];
    private static readonly HashSet<IPFamily> Both = [IPFamily.IPv4, IPFamily.IPv6];

    private static IPFamilyLeakInput Input(string[] allowed, string[] address, bool acknowledged = false) =>
        new(Guid.NewGuid(), new TunnelRouting(address, allowed, []), acknowledged);

    private static IReadOnlyDictionary<Guid, IReadOnlyList<IPFamilyLeak>> Leaks(IPFamilyLeakInput[] connected,
        HashSet<IPFamily>? physical = null, HashSet<IPFamily>? bypassed = null, bool killSwitch = false) =>
        IPFamilyLeakDetector.Leaks(connected, physical ?? Both, bypassed ?? [], killSwitch);

    private static IPFamilyLeak L(IPFamily f, IPFamilyLeakReason r) => new(f, r);

    [Fact]
    public void DetectsMissingAddressesAndUnroutedFamilies()
    {
        var home = Input(All, ["10.10.0.2/32"]);
        Assert.Equal([L(IPFamily.IPv6, IPFamilyLeakReason.MissingAddress)], Leaks([home])[home.Id]);
        Assert.Empty(Leaks([Input(All, ["10.10.0.2/32", "fd00::2/128"])]));

        var v4Full = Input(["0.0.0.0/0"], ["10.10.0.2/32"]);
        Assert.Empty(Leaks([v4Full], physical: [IPFamily.IPv4]));
        Assert.Equal([L(IPFamily.IPv6, IPFamilyLeakReason.NotRouted)], Leaks([v4Full])[v4Full.Id]);
        var v6Full = Input(["::/0"], ["fd00::2/128"]);
        Assert.Equal([L(IPFamily.IPv4, IPFamilyLeakReason.NotRouted)], Leaks([v6Full])[v6Full.Id]);

        var bothBroken = Input(["::/0"], ["10.10.0.2/32"]);
        Assert.Equal([L(IPFamily.IPv4, IPFamilyLeakReason.NotRouted), L(IPFamily.IPv6, IPFamilyLeakReason.MissingAddress)],
            Leaks([bothBroken])[bothBroken.Id]); // IPv4 first
        Assert.Empty(Leaks([Input(["10.0.0.0/8"], ["10.10.0.2/32"])])); // a split tunnel never warns
    }

    [Fact]
    public void OtherConnectedTunnelsCoverTheFamily()
    {
        var v4Full = Input(["0.0.0.0/0"], ["10.10.0.2/32"]);
        Assert.Empty(Leaks([v4Full, Input(["::/0"], ["2001:db8::2/128"])]));
        Assert.Empty(Leaks([Input(All, ["10.0.0.2/32", "fd00::2/128"]), Input(All, ["10.1.0.2/32", "fd01::2/128"])]));
        var other = Input(["0.0.0.0/0"], ["10.20.0.2/32"]);
        var both = Leaks([v4Full, other]);
        Assert.Equal([L(IPFamily.IPv6, IPFamilyLeakReason.NotRouted)], both[v4Full.Id]);
        Assert.Equal([L(IPFamily.IPv6, IPFamilyLeakReason.NotRouted)], both[other.Id]);
        Assert.Empty(Leaks([Input(All, ["10.0.0.2/32", "fd00::2/128"], acknowledged: true), v4Full]));
    }

    [Fact]
    public void AcknowledgingSilencesTheWarningButNotTheLabel()
    {
        var acknowledged = Input(All, ["10.10.0.2/32"], acknowledged: true);
        var leaks = Leaks([acknowledged]);
        Assert.Equal([L(IPFamily.IPv6, IPFamilyLeakReason.MissingAddress)], leaks[acknowledged.Id]);
        Assert.Empty(IPFamilyLeakDetector.Warnings(leaks, [acknowledged]));
        var home = Input(All, ["10.10.0.2/32"]);
        Assert.Single(IPFamilyLeakDetector.Warnings(Leaks([home]), [home]));
        Assert.Equal("All IPv4 traffic", IPFamilyLeakDetector.RouteLabel(All, leaks[acknowledged.Id]));
    }

    [Fact]
    public void RouteLabels()
    {
        Assert.Equal("All traffic (IPv4+IPv6)", IPFamilyLeakDetector.RouteLabel(All, []));
        Assert.Equal("All IPv4 traffic", IPFamilyLeakDetector.RouteLabel(["0.0.0.0/0"], []));
        Assert.Equal("All IPv6 traffic", IPFamilyLeakDetector.RouteLabel(["::/0"], []));
        Assert.Null(IPFamilyLeakDetector.RouteLabel(["10.0.0.0/8"], []));
    }

    [Fact]
    public void BypassedRoutesAndTheKillSwitch()
    {
        var dual = Input(All, ["10.10.0.2/32", "fd00::2/128"]);
        var bypassed = Leaks([dual], bypassed: [IPFamily.IPv6]);
        Assert.Equal([L(IPFamily.IPv6, IPFamilyLeakReason.RouteBypassed)], bypassed[dual.Id]);
        Assert.Null(bypassed[dual.Id][0].FixDescription);
        Assert.Empty(Leaks([Input(All, ["10.10.0.2/32"])], killSwitch: true));
    }

    [Fact]
    public void Copy()
    {
        var missing = L(IPFamily.IPv6, IPFamilyLeakReason.MissingAddress);
        Assert.Equal("IPv6 is leaking", missing.Title);
        Assert.Equal("This tunnel has no IPv6 address, so IPv6 traffic goes around it.", missing.Problem);
        Assert.Equal("The fix disables IPv6 for this tunnel by adding a placeholder IPv6 address.", missing.FixDescription);
        var notRouted = L(IPFamily.IPv4, IPFamilyLeakReason.NotRouted);
        Assert.Equal("This tunnel does not route IPv4, and this network has IPv4, so IPv4 traffic goes around it.", notRouted.Problem);
        Assert.Equal("The fix disables IPv4 for this tunnel by routing it into the tunnel with a placeholder address.", notRouted.FixDescription);
        Assert.Equal("The tunnel is set to route all IPv6 traffic, but Windows sends it around the tunnel.",
            L(IPFamily.IPv6, IPFamilyLeakReason.RouteBypassed).Problem);
    }

    [Fact]
    public void LeakWarningsJoinTheTunnelWarnings()
    {
        var tunnel = new Tunnel { Name = "home", IsActive = true, AllowedIPs = [.. All], Address = ["10.10.0.2/32"] };
        var leak = L(IPFamily.IPv6, IPFamilyLeakReason.MissingAddress);
        var warning = Assert.Single(TunnelWarnings.Compute([tunnel], new HashSet<Guid>(),
            new Dictionary<Guid, IReadOnlyList<IPFamilyLeak>> { [tunnel.Id] = [leak] }));
        Assert.Equal("IPv6 Leak", warning.Title);
        Assert.StartsWith("\"home\": This tunnel has no IPv6 address", warning.Message);
    }
}

/// Port of Tests/IPFamilyLeakFixTests.swift.
public class IPFamilyLeakFixTests
{
    private static readonly string V6Comment = IPFamilyLeakFix.MarkerComment(IPFamily.IPv6);

    [Fact]
    public void AddsACommentedPlaceholderAndNothingElse()
    {
        Assert.Equal("# Placeholder address added by WireTunnels to keep IPv6 from leaking. Remove it once the tunnel has a real IPv6 address.", V6Comment);
        var home = "[Interface]\nPrivateKey = KEY\n# my note\nAddress = 10.10.0.2/32\nDNS = 192.168.88.1\nMTU = 1380\n\n[Peer]\nPublicKey = PEER\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = vpn.example:13231\n";
        var fixedHome = IPFamilyLeakFix.Apply(home, IPFamily.IPv6, "fd12:3456:789a::1/128");
        Assert.Equal($"[Interface]\nPrivateKey = KEY\n# my note\n{V6Comment}\nAddress = 10.10.0.2/32, fd12:3456:789a::1/128\nDNS = 192.168.88.1\nMTU = 1380\n\n[Peer]\nPublicKey = PEER\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = vpn.example:13231\n", fixedHome);
        Assert.Equal(fixedHome, IPFamilyLeakFix.Apply(fixedHome, IPFamily.IPv6, "fd99::1/128"));
    }

    [Theory]
    [InlineData("[Interface]\nAddress = 10.10.0.2/32\n[Peer]\nAllowedIPs = 0.0.0.0/0\n", "IPv6",
        "[Interface]\nV6\nAddress = 10.10.0.2/32, fd12::1/128\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n")]
    [InlineData("[Interface]\nAddress = fd00::2/128\n[Peer]\nAllowedIPs = ::/0\n", "IPv4",
        "[Interface]\nV4\nAddress = fd00::2/128, 198.18.7.9/32\n[Peer]\nAllowedIPs = ::/0, 0.0.0.0/0\n")]
    [InlineData("[interface]\naddress = 10.10.0.2/32\n[peer]\nallowedips = 0.0.0.0/0\n", "IPv6",
        "[interface]\nV6\naddress = 10.10.0.2/32, fd12::1/128\n[peer]\nallowedips = 0.0.0.0/0, ::/0\n")]
    [InlineData("[Interface]\nPrivateKey = KEY\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n", "IPv6",
        "[Interface]\nV6\nAddress = fd12::1/128\nPrivateKey = KEY\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n")]
    [InlineData("[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nAllowedIPs = 0.0.0.0/0\n[Peer]\nAllowedIPs = 10.9.0.0/16\n", "IPv6",
        "[Interface]\nV6\nAddress = 10.0.0.2/32, fd12::1/128\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n[Peer]\nAllowedIPs = 10.9.0.0/16\n")]
    [InlineData("[Interface]\r\nAddress = 10.0.0.2/32\r\n[Peer]\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\n", "IPv6",
        "[Interface]\r\nV6\r\nAddress = 10.0.0.2/32, fd12::1/128\r\n[Peer]\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\n")]
    public void EditsOnlyWhatIsMissing(string config, string familyName, string expected)
    {
        var family = Enum.Parse<IPFamily>(familyName);
        var placeholder = family == IPFamily.IPv6 ? "fd12::1/128" : "198.18.7.9/32";
        Assert.Equal(expected.Replace("V6", V6Comment).Replace("V4", IPFamilyLeakFix.MarkerComment(IPFamily.IPv4)),
            IPFamilyLeakFix.Apply(config, family, placeholder));
    }

    [Fact]
    public void PlaceholdersHaveTheRightShape()
    {
        var random = new Random(42);
        for (var i = 0; i < 50; i++)
        {
            var v6 = IPFamilyLeakFix.PlaceholderAddress(IPFamily.IPv6, random);
            Assert.Matches(new Regex("^fd[0-9a-f]{2}:[0-9a-f]{1,4}:[0-9a-f]{1,4}::1/128$"), v6);
            Assert.Equal(IPFamily.IPv6, IPFamilyRouting.FamilyOf(v6));
            var v4 = IPFamilyLeakFix.PlaceholderAddress(IPFamily.IPv4, random);
            Assert.Matches(new Regex("^198\\.1[89]\\.\\d{1,3}\\.\\d{1,3}/32$"), v4);
            var last = int.Parse(v4.Split('/')[0].Split('.')[3]);
            Assert.InRange(last, 1, 254);
            Assert.True(IPPrefix.TryParse(v4, out _));
        }
    }

    [Fact]
    public void FixAvailability()
    {
        var missing = new IPFamilyLeak(IPFamily.IPv6, IPFamilyLeakReason.MissingAddress);
        IPFamilyLeakFix.UnavailableReason? Reason(IPFamilyLeak? leak = null, string[]? dns = null, bool managed = false, bool inventory = false, bool busy = false) =>
            IPFamilyLeakFix.Unavailable(leak ?? missing, dns ?? ["1.1.1.1"], managed, inventory, busy);
        Assert.Null(Reason());
        Assert.Equal(IPFamilyLeakFix.UnavailableReason.RouteBypassed, Reason(new IPFamilyLeak(IPFamily.IPv6, IPFamilyLeakReason.RouteBypassed)));
        Assert.Equal(IPFamilyLeakFix.UnavailableReason.Managed, Reason(managed: true));
        Assert.Equal(IPFamilyLeakFix.UnavailableReason.InventoryProtected, Reason(inventory: true));
        Assert.Equal(IPFamilyLeakFix.UnavailableReason.Busy, Reason(busy: true));
        Assert.Equal(IPFamilyLeakFix.UnavailableReason.DnsUsesFamily, Reason(dns: ["2606:4700:4700::1111"]));
        Assert.Null(Reason(dns: ["2606:4700:4700::1111", "1.1.1.1"]));
        Assert.Null(Reason(dns: []));
        Assert.Null(Reason(dns: ["home.lan"]));
        Assert.Equal("The fix is not available because this tunnel's DNS servers use IPv6.", IPFamilyLeakFix.DnsUnavailableMessage(IPFamily.IPv6));
    }
}
