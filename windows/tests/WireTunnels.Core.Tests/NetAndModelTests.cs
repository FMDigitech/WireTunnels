using System.Text.Json;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;
using WireTunnels.Core.Storage;

namespace WireTunnels.Core.Tests;

public class IPPrefixTests
{
    [Theory]
    [InlineData("10.1.2.3/8", "10.0.0.0/8")]
    [InlineData("0::/0", "::/0")]
    [InlineData("fd00::1", "fd00::1/128")]
    [InlineData("192.168.1.7", "192.168.1.7/32")]
    [InlineData("::ffff:1.2.3.4/128", "::ffff:1.2.3.4/128")]
    public void ParsesAndCanonicalizes(string text, string canonical) => Assert.Equal(canonical, IPPrefix.Parse(text).ToString());

    [Theory]
    [InlineData("1")]
    [InlineData("0x7f.0.0.1")]
    [InlineData("010.0.0.1")]
    [InlineData("1.2.3")]
    [InlineData("1.2.3.256")]
    [InlineData("10.0.0.0/33")]
    [InlineData("10.0.0.0/")]
    [InlineData("10.0.0.0/+8")]
    [InlineData("fe80::1%eth0")]
    [InlineData("example.com")]
    [InlineData("::/129")]
    public void RejectsAmbiguousOrInvalid(string text) => Assert.False(IPPrefix.TryParse(text, out _));

    [Fact]
    public void ContainmentAndOverlap()
    {
        var net = IPPrefix.Parse("10.0.0.0/8");
        Assert.True(net.Contains(IPPrefix.Parse("10.1.0.0/16")));
        Assert.False(IPPrefix.Parse("10.1.0.0/16").Contains(net));
        Assert.True(IPPrefix.Parse("10.1.0.0/16").Overlaps(net));
        Assert.False(net.Contains(IPPrefix.Parse("::/0")));
        Assert.True(net.ContainsAddress("10.200.1.1"));
        Assert.True(IPPrefix.Parse("fe80::/10").ContainsAddress("fe80::1%12"));
        Assert.False(net.ContainsAddress("10.0.0.1%1"));
    }

    [Fact]
    public void NormalizedDeduplicatesAndSorts() =>
        Assert.Equal(["10.0.0.0/8", "192.168.0.0/16", "::/0"], IPPrefix.Normalized(["::/0", "192.168.1.1/16", "10.0.0.0/8", "10.9.9.9/8"]));
}

public class IPFamilyRoutingTests
{
    [Fact]
    public void DefaultRouteOrBothHalves()
    {
        Assert.True(IPFamilyRouting.RoutesAll(IPFamily.IPv4, ["0.0.0.0/0"]));
        Assert.True(IPFamilyRouting.RoutesAll(IPFamily.IPv4, ["0.0.0.0/1", "128.0.0.0/1"]));
        Assert.False(IPFamilyRouting.RoutesAll(IPFamily.IPv4, ["0.0.0.0/1"]));
        Assert.True(IPFamilyRouting.RoutesAll(IPFamily.IPv6, ["0::/0 # all"]));
        Assert.False(IPFamilyRouting.RoutesAll(IPFamily.IPv6, ["0.0.0.0/0"]));
    }

    [Fact]
    public void InternetFamiliesIgnoreLinkLocal()
    {
        Assert.Empty(IPFamilyRouting.InternetFamilies(["169.254.3.4", "fe80::1%3", "fd00::5"]));
        Assert.Equal(new HashSet<IPFamily> { IPFamily.IPv4, IPFamily.IPv6 },
            IPFamilyRouting.InternetFamilies(["192.168.1.10", "2a01:4f8::1"]).ToHashSet());
    }
}

public class AutoConnectTests
{
    [Fact]
    public void MatchesWifiBySsidAndEthernetBySubnet()
    {
        var wifi = new AutoConnectNetworkMatch { Enabled = true, Interface = AutoConnectInterface.Wifi, WifiSSIDs = ["Office"] };
        Assert.True(wifi.Matches(false, [], true, "Office"));
        Assert.False(wifi.Matches(false, [], true, "Cafe"));
        Assert.False(wifi.Matches(true, ["10.0.0.5"], false, null));

        var eth = new AutoConnectNetworkMatch { Enabled = true, Interface = AutoConnectInterface.Ethernet, EthernetSubnets = ["10.0.0.0/24"] };
        Assert.True(eth.Matches(true, ["10.0.0.5"], false, null));
        Assert.False(eth.Matches(true, ["10.0.1.5"], false, null));

        var any = new AutoConnectNetworkMatch { Enabled = true, Interface = AutoConnectInterface.Both };
        Assert.True(any.Matches(false, [], true, null));
        Assert.False(new AutoConnectNetworkMatch().Matches(true, [], true, "x"));
    }
}

public class TunnelJsonTests
{
    [Fact]
    public void ReadsMacOSShapeWithDefaults()
    {
        const string json = """
            [{"id":"5D5F1D1E-6C3A-4E54-9B5C-0F6A3B7C9D11","name":"Office","configPath":"/x/Office.conf",
              "isActive":false,"isFavorite":true,"autostart":false,"allowedIPs":["10.0.0.0/8"],"dns":[],
              "rxBytes":0,"txBytes":0,"createdAt":"2026-01-02T03:04:05Z","updatedAt":"2026-01-02T03:04:05Z",
              "scope":"managed","managedPolicy":{"usersCanConnect":false},
              "autoConnectRule":{"connect":{"enabled":true,"interface":"both","wifiSSIDs":["A"]}}}]
            """;
        var t = JsonSerializer.Deserialize<List<Tunnel>>(json, CoreJson.Options)!.Single();
        Assert.Equal(TunnelScope.Managed, t.Scope);
        Assert.True(t.IsFavorite);
        Assert.False(t.ManagedPolicy!.UsersCanConnect);
        Assert.True(t.ManagedPolicy.UsersCanDisconnect);
        Assert.Empty(t.ExcludedRoutes);
        Assert.Equal(AutoConnectInterface.Both, t.AutoConnectRule.Connect.Interface);
        Assert.False(t.AutoConnectRule.Disconnect.Enabled);
        Assert.Equal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero), t.CreatedAt);

        var round = JsonSerializer.Serialize(t, CoreJson.Options);
        Assert.Contains("\"scope\": \"managed\"", round);
        Assert.Contains("\"splitDNSDomains\"", round);
        Assert.DoesNotContain("effectiveSplitDNSDomains", round);
    }
}

public class TunnelWarningsTests
{
    private static Tunnel T(string name, bool active, string[] allowed, string[]? dns = null) =>
        new() { Name = name, IsActive = active, AllowedIPs = [.. allowed], Dns = [.. dns ?? []] };

    [Fact]
    public void DetectsConflicts()
    {
        var a = T("A", true, ["0.0.0.0/0"], ["1.1.1.1"]);
        var b = T("B", true, ["0.0.0.0/1", "128.0.0.0/1"], ["8.8.8.8"]);
        var c = T("C", false, ["10.0.0.0/8"]);
        var kinds = TunnelWarnings.Compute([a, b, c], new HashSet<Guid> { c.Id }).Select(w => w.Kind).ToList();
        Assert.Equal([TunnelWarningKind.MultipleFullTunnels, TunnelWarningKind.OverlappingAllowedIPs,
                      TunnelWarningKind.ConflictingDns, TunnelWarningKind.KillSwitchBlocking], kinds);
    }

    [Fact]
    public void DisjointTunnelsHaveNoWarnings() =>
        Assert.Empty(TunnelWarnings.Compute([T("A", true, ["10.0.0.0/16"], ["10.0.0.1"]), T("B", true, ["10.1.0.0/16"], ["10.0.0.1"])],
            new HashSet<Guid>()));
}

public class RecoverableJsonStoreTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("wt-store-").FullName;
    private string File_ => Path.Combine(_dir, "metadata", "tunnels.json");
    private RecoverableJsonStore<List<Tunnel>> Store() => new(File_, () => []);

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void MissingStoreIsEmptyAndRoundTrips()
    {
        var store = Store();
        Assert.Empty(store.Load());
        store.Save([new Tunnel { Name = "A" }]);
        Assert.Equal("A", Store().Load().Single().Name);
        Assert.True(File.Exists(File_ + ".backup"));
    }

    [Fact]
    public void CorruptPrimaryRecoversFromBackupAndIsPreservedOnSave()
    {
        var store = Store();
        store.Save([new Tunnel { Name = "A" }]);
        store.Save([new Tunnel { Name = "B" }]);
        File.WriteAllText(File_, "{ not json");

        var recovered = Store();
        Assert.Equal("A", recovered.Load().Single().Name); // backup holds the previous snapshot
        Assert.NotNull(recovered.RecoveryWarning);

        recovered.Save([new Tunnel { Name = "C" }]);
        Assert.Single(Directory.GetFiles(Path.GetDirectoryName(File_)!, "tunnels.json.corrupt-*"));
        Assert.Equal("C", Store().Load().Single().Name);
    }

    [Fact]
    public void CorruptPrimaryWithoutBackupIsNeverOverwritten()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(File_)!);
        File.WriteAllText(File_, "garbage");
        Assert.Throws<MetadataStorageException>(() => Store().Load());
        Assert.Throws<MetadataStorageException>(() => Store().Save([]));
        Assert.Equal("garbage", File.ReadAllText(File_));
    }
}
