using System.ComponentModel;
using System.Text.Json;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Net;
using WireTunnels.Service.Ipc;
using WireTunnels.Service.Network;

namespace WireTunnels.Service.Tests;

/// Port of Tests/InventoryRoutingTests.swift (policies, failures, rollback, ownership, restoration)
/// against the Windows policy: WFP guards instead of pf tables, route rows instead of PF_ROUTE.
public class InventoryPolicyTests
{
    private const string Alice = "S-1-5-21-1-1001", Bob = "S-1-5-21-1-1002";
    private readonly FakeBackend _backend = new();
    private readonly NetworkFakes _net = new();
    private readonly InventoryPolicy _policy;
    private readonly Guid _owner = Guid.NewGuid(), _generation = Guid.NewGuid();
    private readonly string _local = WireGuardKey.Generate().PublicKey, _peer = WireGuardKey.Generate().PublicKey;

    public InventoryPolicyTests() => _policy = _net.Inventory(_backend);

    private InventoryRoutingRequest Request(InventoryAction action, string[]? discovered = null, Guid? generation = null) => new()
    {
        Action = action, OwnerId = _owner, Generation = generation ?? _generation, Name = "office",
        LocalPublicKey = _local, PeerPublicKey = _peer,
        StaticPrefixes = ["192.0.2.0/24", "2001:db8::1"], DiscoveredPrefixes = [.. discovered ?? []],
        EndpointHost = "198.51.100.9", EndpointPort = 51820,
    };

    private async Task Connect()
    {
        await _backend.StartAsync("office", null!, false, default);
        _backend.Keys["office"] = (_local, _peer, "198.51.100.9:51820");
    }

    private InventoryGuard Guard => Assert.Single(_net.InventoryGuards);
    private static string[] Strings(IEnumerable<IPPrefix> prefixes) => [.. prefixes.Select(p => p.ToString())];

    [Fact]
    public async Task ProtectBlocksEverywhereThenApplyOpensOnlyTheTunnel()
    {
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        Assert.Null(Guard.AllowedLuid); // static prefixes blocked before the connection
        Assert.Equal(["192.0.2.0/24", "2001:db8::1/128"], Strings(Guard.Prefixes));
        Assert.Equal("198.51.100.9:51820", Guard.Endpoint!.ToString()); // the tunnel can still connect

        await Connect();
        _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.7", "192.0.2.7"]), Alice);
        Assert.Equal(["192.0.2.0/24", "192.0.2.7/32", "203.0.113.7/32", "2001:db8::1/128"], Strings(_backend.PeerAllowedIPs["office"]));
        // 192.0.2.7 is inside a static prefix, whose route the tunnel already has.
        Assert.Equal([$"add 203.0.113.7/32 {_backend.Luid("office")}"], _net.RouteLog);
        Assert.Equal(_backend.Luid("office"), Guard.AllowedLuid);
        Assert.Contains("203.0.113.7/32", Strings(Guard.Prefixes));
    }

    [Fact]
    public async Task UnchangedInventoryIsANoOpAndARefreshReplacesOwnedRoutes()
    {
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        await Connect();
        _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.7"]), Alice);
        var guards = _net.InventoryGuards;
        _net.RouteLog.Clear();
        _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.7"]), Alice);
        Assert.Empty(_net.RouteLog);
        Assert.Same(guards, _net.InventoryGuards);

        _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.8"]), Alice);
        var luid = _backend.Luid("office");
        Assert.Equal([$"add 203.0.113.8/32 {luid}", $"delete 203.0.113.7/32 {luid}"], _net.RouteLog);
    }

    [Fact]
    public async Task StoppingTheTunnelClosesItsExceptionButKeepsTheCache()
    {
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        await Connect();
        _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.8"]), Alice);
        _backend.Stop("office");
        _policy.TunnelStopped("office");
        Assert.Null(Guard.AllowedLuid);
        Assert.Contains("203.0.113.8/32", Strings(Guard.Prefixes)); // cached destinations stay blocked
        Assert.Empty(_net.Saved.Single().OwnedRoutes);

        // Reconnect with an empty app cache: the service's cache wins.
        _policy.Perform(Request(InventoryAction.Protect, generation: Guid.NewGuid()), Alice);
        Assert.Equal(["203.0.113.8/32"], _net.Saved.Single().DiscoveredPrefixes);
    }

    [Fact]
    public async Task RemoveDropsThePolicyAndItsRoutes()
    {
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        await Connect();
        _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.8"]), Alice);
        Assert.Throws<RequestException>(() => _policy.Perform(InventoryRoutingRequest.Removal(_owner), Bob));
        _policy.Perform(InventoryRoutingRequest.Removal(_owner), Alice);
        Assert.Empty(_net.InventoryGuards);
        Assert.Empty(_net.Saved);
        Assert.Empty(_net.Routes);
    }

    [Fact]
    public async Task ApplyNeedsTheCurrentGenerationAndTheSameTunnelIdentity()
    {
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        await Connect();
        Assert.Throws<RequestException>(() => _policy.Perform(Request(InventoryAction.Apply, generation: Guid.NewGuid()), Alice));
        _backend.Keys["office"] = (WireGuardKey.Generate().PublicKey, _peer, "198.51.100.9:51820"); // another config under the same alias
        Assert.Throws<RequestException>(() => _policy.Perform(Request(InventoryAction.Apply), Alice));
        Assert.Null(Guard.AllowedLuid);
        Assert.Empty(_backend.PeerAllowedIPs);
    }

    [Fact]
    public async Task AFailedUpdateFailsClosed()
    {
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        await Connect();
        _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.1"]), Alice);
        _backend.FailPeerUpdate = new Win32Exception(87);
        var e = Assert.Throws<RequestException>(() => _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.2"]), Alice));
        Assert.Contains("remain blocked", e.Message);
        Assert.Null(Guard.AllowedLuid);
        // Both the old and the attempted destinations are blocked; the old cache is kept.
        Assert.Contains("203.0.113.1/32", Strings(Guard.Prefixes));
        Assert.Contains("203.0.113.2/32", Strings(Guard.Prefixes));
        Assert.Equal(["203.0.113.1/32"], _net.Saved.Single().DiscoveredPrefixes);
    }

    [Fact]
    public void PoliciesCannotOverlapOrBelongToSomeoneElse()
    {
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        var other = Request(InventoryAction.Protect);
        other.OwnerId = Guid.NewGuid();
        other.StaticPrefixes = ["192.0.2.128/25"];
        Assert.Contains("overlap", Assert.Throws<RequestException>(() => _policy.Perform(other, Bob)).Message);
        Assert.Contains("another user", Assert.Throws<RequestException>(() => _policy.Perform(Request(InventoryAction.Protect), Bob)).Message);
    }

    [Theory]
    [InlineData("0.0.0.0/0")]
    [InlineData("127.0.0.1")]
    [InlineData("fe80::1")]
    [InlineData("::ffff:192.0.2.1")]
    [InlineData("hostname")]
    public void DiscoveredPrefixesAreValidated(string invalid)
    {
        Assert.Throws<RequestException>(() => _policy.Perform(Request(InventoryAction.Protect, [invalid]), Alice));
        Assert.Empty(_net.Saved);
    }

    [Fact]
    public async Task ARestartRestoresBlocksWithoutTrustingStoredAdapters()
    {
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        await Connect();
        _policy.Perform(Request(InventoryAction.Apply, ["203.0.113.8"]), Alice);

        var restarted = new NetworkFakes { Saved = _net.Saved };
        var policy = restarted.Inventory(new FakeBackend());
        policy.Restore();
        var guard = Assert.Single(restarted.InventoryGuards);
        Assert.Null(guard.AllowedLuid);
        Assert.Contains("203.0.113.8/32", Strings(guard.Prefixes));
        Assert.Empty(restarted.Saved.Single().OwnedRoutes);
    }

    [Fact]
    public async Task TenThousandAddressesInstallWithoutTruncationAndRepeatAsANoOp()
    {
        var many = Enumerable.Range(0, 10_000).Select(i => $"10.{i / 256}.{i % 256}.1").ToArray();
        _policy.Perform(Request(InventoryAction.Protect), Alice);
        await Connect();
        _policy.Perform(Request(InventoryAction.Apply, many), Alice);
        Assert.Equal(10_000, _net.Saved.Single().OwnedRoutes.Count);
        _net.RouteLog.Clear();
        _policy.Perform(Request(InventoryAction.Apply, many), Alice);
        Assert.Empty(_net.RouteLog);
        // The guard splits large inventories into filters of bounded size.
        Assert.True(FirewallRules.Inventory(_net.InventoryGuards).All(f => f.Conditions.Count <= FirewallRules.InventoryChunk + 1));
    }

    [Fact]
    public async Task TheDispatcherOnlyAppliesThroughTheCallersOwnTunnel()
    {
        var d = _net.Dispatcher(_backend);
        Task<Response> Call(InventoryRoutingRequest r, string sid) => d.HandleAsync(
            new Request { Op = Ops.UpdateInventoryRouting, Args = JsonSerializer.SerializeToNode(r, Protocol.Json)!.AsObject() },
            new ClientIdentity(sid, sid, false), default);
        Assert.True((await Call(Request(InventoryAction.Protect), Alice)).Ok);
        Assert.False((await Call(Request(InventoryAction.Apply), Alice)).Ok); // not connected
        var config = $"""
            [Interface]
            PrivateKey = {WireGuardKey.Generate().PrivateKey}
            Address = 10.0.0.2/32
            [Peer]
            PublicKey = {_peer}
            AllowedIPs = 192.0.2.0/24
            """;
        await d.HandleAsync(new Request { Op = Ops.StartTunnel, Args = JsonSerializer.SerializeToNode(new StartTunnelArgs { Name = "office", Contents = config }, Protocol.Json)!.AsObject() },
            new ClientIdentity(Bob, Bob, false), default);
        _backend.Keys["office"] = (_local, _peer, "198.51.100.9:51820");
        Assert.False((await Call(Request(InventoryAction.Apply), Alice)).Ok); // Bob's tunnel
        await d.HandleAsync(new Request { Op = Ops.StopTunnel, Args = JsonSerializer.SerializeToNode(new TunnelNameArgs { Name = "office" }, Protocol.Json)!.AsObject() },
            new ClientIdentity(Bob, Bob, false), default);
    }
}

/// Port of the prefix checks in Tests/InventoryRoutingTests.swift.
public class InventoryPrefixTests
{
    [Fact]
    public void ParsesAndValidatesCommandOutput()
    {
        Assert.Equal(["192.0.2.0/24", "192.0.2.4/32", "2001:db8::1/128"], IPPrefix.Normalized(["192.0.2.17/24", "192.0.2.0/24", "2001:0DB8::1", "192.0.2.4"]));
        Assert.Equal(2, IPPrefix.ParseInventoryOutput("192.0.2.1,\n2001:db8::2\t192.0.2.1"u8).Count);
        Assert.Throws<FormatException>(() => IPPrefix.ParseInventoryOutput("192.0.2.1\ninvalid"u8));
        Assert.Throws<FormatException>(() => IPPrefix.ParseInventoryOutput(""u8));
        Assert.Throws<FormatException>(() => IPPrefix.Normalized(Enumerable.Repeat("192.0.2.1", 100_001)));
        foreach (var invalid in new[] { "0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1", "127.0.0.1", "169.254.1.1", "::1", "fe80::1", "ff02::1", "::ffff:192.0.2.1" })
            Assert.Throws<FormatException>(() => IPPrefix.ParseInventoryOutput(System.Text.Encoding.UTF8.GetBytes(invalid)));
        Assert.Equal(2, IPPrefix.InventoryPrefixes(["10.0.0.0/8", "2001:db8::/32"]).Count);
    }

    [Fact]
    public void RangeIndexHandlesNestedCoveringAndDisjointRanges()
    {
        var index = new IPPrefixIndex(new[] { "10.0.0.0/8", "10.1.0.0/16", "192.0.2.1", "2001:db8::/32" }.Select(IPPrefix.Parse));
        Assert.True(index.Contains(IPPrefix.Parse("10.1.2.3")));
        Assert.True(index.Overlaps(IPPrefix.Parse("192.0.2.0/24")));
        Assert.False(index.Overlaps(IPPrefix.Parse("198.51.100.1")));
        Assert.False(index.Contains(IPPrefix.Parse("192.0.2.0/24")));
    }

    [Fact]
    public void GuardFiltersBlockBothDirectionsOutsideTheTunnelAndKeepTheEndpointOpen()
    {
        var filters = FirewallRules.Inventory([new InventoryGuard([IPPrefix.Parse("192.0.2.0/24"), IPPrefix.Parse("2001:db8::/32")], 42,
            new System.Net.IPEndPoint(System.Net.IPAddress.Parse("198.51.100.9"), 51820))]);
        var blocks = filters.Where(f => !f.Permit).ToList();
        Assert.Equal(4, blocks.Count); // connect and receive, IPv4 and IPv6
        Assert.All(blocks, b => Assert.Contains(b.Conditions, c => c.Field == WfpField.LocalInterface && c.NotEqual && c.Number == 42));
        var endpoint = Assert.Single(filters, f => f.Permit);
        Assert.True(endpoint.Weight > blocks[0].Weight);
        // Outranks the kill switch's adapter permit, so no other tunnel can carry these destinations.
        Assert.True(blocks[0].Weight > FirewallRules.KillSwitch([new KillSwitchRule(1, System.Net.IPAddress.Loopback, 1)]).First(f => f.Permit).Weight);
        Assert.DoesNotContain(FirewallRules.Inventory([new InventoryGuard([IPPrefix.Parse("192.0.2.0/24")], null, null)]).SelectMany(f => f.Conditions),
            c => c.Field == WfpField.LocalInterface);
    }
}
