using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Net;
using WireTunnels.Core.Models;
using WireTunnels.Core.Storage;
using WireTunnels.Service.Ipc;
using WireTunnels.Service.Managed;
using WireTunnels.Service.Network;
using WireTunnels.Service.WireGuard;

namespace WireTunnels.Service.Tests;

internal sealed class FakeBackend : ITunnelBackend
{
    public readonly HashSet<string> Running = [];
    public readonly List<string> SuppressedDns = [];
    private readonly Dictionary<string, ulong> _luids = [];
    private ulong _next = 100;

    public Task StartAsync(string alias, WireGuardConfig config, bool suppressDns, CancellationToken ct)
    {
        Running.Add(alias);
        _luids[alias] = _next++; // a new adapter gets a new LUID
        if (suppressDns) SuppressedDns.Add(alias);
        return Task.CompletedTask;
    }

    public void Stop(string alias)
    {
        Running.Remove(alias);
        _luids.Remove(alias);
    }

    public bool IsRunning(string alias) => Running.Contains(alias);
    /// Keys of each running tunnel, as WireGuardGetConfiguration reports them.
    public readonly Dictionary<string, (string Local, string Peer, string Endpoint)> Keys = [];
    public readonly Dictionary<string, IReadOnlyList<IPPrefix>> PeerAllowedIPs = [];
    public Exception? FailPeerUpdate;

    public TunnelRuntimeStatus Status(string alias) => Keys.TryGetValue(alias, out var k)
        ? new() { Name = alias, PublicKey = k.Local, Peers = [new PeerRuntimeStatus { PublicKey = k.Peer, Endpoint = k.Endpoint }] }
        : new() { Name = alias };

    public void SetPeerAllowedIPs(string alias, string peerPublicKey, IReadOnlyList<IPPrefix> allowed)
    {
        if (FailPeerUpdate is { } e) throw e;
        PeerAllowedIPs[alias] = allowed;
    }
    public ulong? Luid(string alias) => _luids.TryGetValue(alias, out var luid) ? luid : null;
    public IReadOnlySet<ulong> Luids => _luids.Values.ToHashSet();
}

internal sealed class FakeManagedStore : IManagedStore
{
    public List<Tunnel> Records = [];
    public readonly Dictionary<Guid, string> Configs = [];
    public SystemSettings Settings = new();
    private static Tunnel Copy(Tunnel t) => JsonSerializer.Deserialize<Tunnel>(JsonSerializer.Serialize(t, CoreJson.Options), CoreJson.Options)!;
    public List<Tunnel> Load() => Records.Select(Copy).ToList();
    public void Save(IReadOnlyList<Tunnel> records) => Records = records.Select(Copy).ToList();
    public string ReadConfig(Guid id) => Configs.TryGetValue(id, out var c) ? c : throw new InvalidDataException("missing");
    public void WriteConfig(Guid id, string contents) => Configs[id] = contents;
    public void DeleteConfig(Guid id) => Configs.Remove(id);
    public SystemSettings LoadSettings() => Settings;
    public void SaveSettings(SystemSettings settings) => Settings = settings;
}

/// Records what the policy asks of the firewall, NRPT, routing table and journal.
internal sealed class NetworkFakes : IFirewall, INrptStore, IRouteTable, IJournal, IInventoryStore
{
    public List<InventoryRecord> Saved = [];
    List<InventoryRecord> IInventoryStore.Load() => Saved.Select(r => r.Copy()).ToList();
    void IInventoryStore.Save(IReadOnlyList<InventoryRecord> records) => Saved = records.Select(r => r.Copy()).ToList();
    public InventoryPolicy Inventory(ITunnelBackend backend) => new(backend, this, this, this, NullLogger<InventoryPolicy>.Instance);
    public readonly FakeManagedStore Managed = new();
    public RequestDispatcher Dispatcher(ITunnelBackend backend) =>
        new(backend, Policy(backend), Inventory(backend), Managed, NullLogger<RequestDispatcher>.Instance);

    public const ulong PhysicalLuid = 1;
    public IReadOnlyList<KillSwitchRule> KillSwitch = [];
    public IReadOnlyList<DnsGuard> DnsGuards = [];
    public readonly Dictionary<string, NrptRule> Nrpt = new(StringComparer.OrdinalIgnoreCase);
    public bool PolicyManaged;
    public readonly List<InstalledRoute> Routes = [];
    public readonly List<string> RouteLog = [];
    public string? Journal;
    public int KillSwitchWrites;

    public NetworkPolicy Policy(ITunnelBackend backend) => new(backend, this, this, this, this, NullLogger<NetworkPolicy>.Instance);

    public void SetKillSwitch(IReadOnlyList<KillSwitchRule> rules) { KillSwitch = rules; KillSwitchWrites++; }
    public void SetDnsGuards(IReadOnlyList<DnsGuard> guards) => DnsGuards = guards;
    public IReadOnlyList<InventoryGuard> InventoryGuards = [];
    public void SetInventoryGuards(IReadOnlyList<InventoryGuard> guards) => InventoryGuards = guards;

    public IReadOnlyDictionary<string, NrptRule> Rules() => new Dictionary<string, NrptRule>(Nrpt);
    public bool ManagedByPolicy() => PolicyManaged;
    public void Write(string key, NrptRule rule) => Nrpt[key] = rule;
    public void Delete(string key) => Nrpt.Remove(key);
    public void Refresh() { }

    public InstalledRoute Add(IPPrefix prefix, ulong? tunnelLuid, IReadOnlySet<ulong> ownAdapters)
    {
        Assert.DoesNotContain(PhysicalLuid, ownAdapters);
        var route = tunnelLuid is { } luid ? new InstalledRoute(prefix.ToString(), luid, null) : new InstalledRoute(prefix.ToString(), PhysicalLuid, "192.168.1.1");
        Routes.Add(route);
        RouteLog.Add($"add {route.Cidr} {route.Luid}");
        return route;
    }

    public void Delete(InstalledRoute route)
    {
        Routes.Remove(route);
        RouteLog.Add($"delete {route.Cidr} {route.Luid}");
    }

    public string? Load() => Journal;
    public void Save(string? json) => Journal = json;
}

/// Port of Tests/KillSwitchRulesTests.swift, plus the Windows-only DNS leak guard.
public class FirewallRulesTests
{
    private static readonly IPAddress Endpoint4 = IPAddress.Parse("198.51.100.7"), Endpoint6 = IPAddress.Parse("2001:db8::7");

    [Fact]
    public void KillSwitchBlocksByDefaultAndPassesTheTunnelAndItsEndpoint()
    {
        var filters = FirewallRules.KillSwitch([new KillSwitchRule(42, Endpoint4, 51820), new KillSwitchRule(null, Endpoint6, 443)]);

        // Every ALE layer blocks unconditionally at the lowest weight; every permit outranks it.
        var blocks = filters.Where(f => !f.Permit).ToList();
        Assert.Equal(4, blocks.Count);
        Assert.All(blocks, b => Assert.Empty(b.Conditions));
        Assert.All(filters.Where(f => f.Permit), p => Assert.True(p.Weight > blocks[0].Weight));
        Assert.Equal(4, filters.Count(f => f.Name == "Permit loopback"));

        // The connected tunnel's adapter passes on every layer; the dropped one has no adapter to pass.
        Assert.Equal(4, filters.Count(f => f.Conditions.Any(c => c.Field == WfpField.LocalInterface)));
        Assert.All(filters.SelectMany(f => f.Conditions).Where(c => c.Field == WfpField.LocalInterface), c => Assert.Equal(42UL, c.Number));

        // The endpoint exception is UDP to that address and port only, on its own family's layers.
        var endpoints = filters.Where(f => f.Name == "Permit WireGuard endpoint").ToList();
        Assert.Equal(4, endpoints.Count);
        Assert.All(endpoints, e =>
        {
            Assert.Contains(e.Conditions, c => c.Field == WfpField.Protocol && c.Number == 17);
            var address = Assert.Single(e.Conditions, c => c.Field == WfpField.RemoteAddress).Address!;
            Assert.Equal(address.Equals(Endpoint4) ? 51820UL : 443UL, Assert.Single(e.Conditions, c => c.Field == WfpField.RemotePort).Number);
            Assert.Equal(address.Equals(Endpoint6), e.Layer is WfpLayer.ConnectV6 or WfpLayer.RecvAcceptV6);
        });
    }

    [Fact]
    public void NoEntriesMeansNoKillSwitch() => Assert.Empty(FirewallRules.KillSwitch([]));

    [Fact]
    public void TheLinkKeepsWorkingUnderTheKillSwitch()
    {
        var filters = FirewallRules.KillSwitch([new KillSwitchRule(null, Endpoint4, 51820)]);
        Assert.Equal(2, filters.Count(f => f.Name == "Permit DHCP"));
        Assert.Equal(2, filters.Count(f => f.Name == "Permit DHCPv6"));
        var ndp = filters.Where(f => f.Name == "Permit NDP").ToList();
        Assert.Equal(2, ndp.Count);
        Assert.All(ndp, n => Assert.Equal([133UL, 134, 135, 136, 137], n.Conditions.Where(c => c.Field == WfpField.IcmpType).Select(c => c.Number)));
    }

    [Fact]
    public void DnsGuardOnlyLetsTheTunnelServersAnswer()
    {
        Assert.Empty(FirewallRules.DnsGuards([]));
        var filters = FirewallRules.DnsGuards([new DnsGuard([IPAddress.Parse("10.0.0.1")])]);
        Assert.All(filters, f => Assert.True(f.Layer is WfpLayer.ConnectV4 or WfpLayer.ConnectV6));
        var blocks = filters.Where(f => !f.Permit).ToList();
        Assert.Equal(2, blocks.Count);
        Assert.All(blocks, b => Assert.Equal(53UL, Assert.Single(b.Conditions).Number));

        var own = Assert.Single(filters, f => f.Name == "Permit tunnel DNS");
        Assert.Equal(WfpLayer.ConnectV4, own.Layer);
        Assert.True(own.Weight > blocks[0].Weight);
        Assert.Equal(2, filters.Count(f => f.Name == "Permit loopback DNS"));
        // The DNS block outranks the kill switch's adapter permit: DNS to another server through the tunnel is blocked too.
        Assert.True(blocks[0].Weight > FirewallRules.KillSwitch([new KillSwitchRule(1, Endpoint4, 1)]).First(f => f.Permit).Weight);
    }
}

public class NetworkPolicyTests
{
    private const string Alice = "S-1-5-21-1-1001", Bob = "S-1-5-21-1-1002";
    private readonly FakeBackend _backend = new();
    private readonly NetworkFakes _net = new();

    private static KillSwitchEntry Entry(string name, string host = "198.51.100.7") => new() { Name = name, EndpointHost = host, EndpointPort = 51820 };

    [Fact]
    public async Task KillSwitchIsTheUnionOfEveryUsersEntriesAndFollowsTheAdapter()
    {
        var policy = _net.Policy(_backend);
        await _backend.StartAsync("office", null!, false, default);
        policy.SyncKillSwitch(Alice, [Entry("office")]);
        policy.SyncKillSwitch(Bob, [Entry("home", "203.0.113.9")]);
        Assert.Equal(2, _net.KillSwitch.Count);
        Assert.Equal(_backend.Luid("office"), _net.KillSwitch.Single(r => r.Endpoint.ToString() == "198.51.100.7").Luid);
        Assert.Null(_net.KillSwitch.Single(r => r.Endpoint.ToString() == "203.0.113.9").Luid);

        // The tunnel drops: still armed, but nothing passes its adapter any more.
        _backend.Stop("office");
        policy.ApplyKillSwitch();
        Assert.All(_net.KillSwitch, r => Assert.Null(r.Luid));

        policy.SyncKillSwitch(Alice, []);
        Assert.Single(_net.KillSwitch);
        policy.SyncKillSwitch(Bob, []);
        Assert.Empty(_net.KillSwitch);
        Assert.False(policy.KillSwitchArmed);
    }

    [Fact]
    public void CrashRecoveryKeepsBlockingAndRemovesStaleRoutes()
    {
        var policy = _net.Policy(_backend);
        policy.SyncKillSwitch(Alice, [Entry("office")]);
        policy.SyncRoutes(Alice, Guid.NewGuid(), [new RouteEntry { Cidr = "192.0.2.0/24" }]);
        Assert.NotNull(_net.Journal);

        // The service process dies; a new one starts during the same boot.
        var restarted = new NetworkFakes { Journal = _net.Journal };
        restarted.Routes.AddRange(_net.Routes);
        var recovered = restarted.Policy(new FakeBackend());
        recovered.Recover();
        Assert.True(recovered.KillSwitchArmed);
        Assert.Null(Assert.Single(restarted.KillSwitch).Luid);
        Assert.Empty(restarted.Routes);
    }

    [Fact]
    public void AFreshBootClearsLeftoverKillSwitchFiltersAndOurNrptRules()
    {
        _net.KillSwitch = [new KillSwitchRule(null, IPAddress.Loopback, 1)];
        _net.Nrpt["WireTunnels-corp.example"] = new NrptRule([".corp.example"], ["10.0.0.1"], SplitDns.Marker(Alice));
        _net.Nrpt["{1234}"] = new NrptRule([".other.example"], ["10.9.9.9"], "");
        _net.Policy(_backend).Recover();
        Assert.Empty(_net.KillSwitch);
        Assert.Equal(["{1234}"], _net.Nrpt.Keys);
    }

    [Fact]
    public void CleanShutdownLeavesNothingBehind()
    {
        var policy = _net.Policy(_backend);
        policy.SyncKillSwitch(Alice, [Entry("office")]);
        policy.SyncRoutes(Alice, Guid.NewGuid(), [new RouteEntry { Cidr = "192.0.2.0/24" }]);
        policy.SyncSplitDns(Alice, new Dictionary<string, IReadOnlyList<string>> { ["corp.example"] = ["10.0.0.1"] });
        policy.Shutdown();
        Assert.Empty(_net.KillSwitch);
        Assert.Empty(_net.Routes);
        Assert.Empty(_net.Nrpt);
        Assert.Null(_net.Journal);
    }

    [Fact]
    public async Task RoutesAreDiffedPerUserAndOwner()
    {
        var policy = _net.Policy(_backend);
        await _backend.StartAsync("hop", null!, false, default);
        var chain = Guid.NewGuid();
        RouteEntry viaHop = new() { Cidr = "203.0.113.5/32", Tunnel = "hop" }, viaGateway = new() { Cidr = "198.51.100.1/32" };
        policy.SyncRoutes(Alice, chain, [viaHop, viaGateway]);
        policy.SyncRoutes(Bob, chain, [viaGateway]);
        Assert.Equal(3, _net.Routes.Count);

        // Re-sending the same state is a no-op; dropping one entry removes exactly that route.
        _net.RouteLog.Clear();
        policy.SyncRoutes(Alice, chain, [viaHop, viaGateway]);
        Assert.Empty(_net.RouteLog);
        policy.SyncRoutes(Alice, chain, [viaGateway]);
        Assert.Equal([$"delete 203.0.113.5/32 {_backend.Luid("hop")}"], _net.RouteLog);

        // Bob's identical route is his own: Alice clearing hers leaves it.
        policy.SyncRoutes(Alice, chain, []);
        Assert.Equal("198.51.100.1/32", Assert.Single(_net.Routes).Cidr);
    }

    [Fact]
    public async Task RoutesOnAStoppedTunnelAreForgottenSoTheyCanBeReadded()
    {
        var policy = _net.Policy(_backend);
        await _backend.StartAsync("hop", null!, false, default);
        var chain = Guid.NewGuid();
        List<RouteEntry> entries = [new() { Cidr = "203.0.113.5/32", Tunnel = "hop" }];
        policy.SyncRoutes(Alice, chain, entries);
        _backend.Stop("hop");
        policy.ForgetTunnel("hop");
        await _backend.StartAsync("hop", null!, false, default);
        _net.RouteLog.Clear();
        policy.SyncRoutes(Alice, chain, entries);
        Assert.Equal([$"add 203.0.113.5/32 {_backend.Luid("hop")}"], _net.RouteLog);
    }
}

/// Port of the ResolverStore rules (Scripts/test_split_dns.sh) on the NRPT.
public class SplitDnsTests
{
    private const string Alice = "S-1-5-21-1-1001", Bob = "S-1-5-21-1-1002";
    private readonly NetworkFakes _nrpt = new();

    private IReadOnlyList<string> Sync(string sid, params (string Domain, string Server)[] rules) =>
        SplitDns.Sync(_nrpt, sid, rules.ToDictionary(r => r.Domain, r => (IReadOnlyList<string>)[r.Server]));

    [Fact]
    public void WritesOneRulePerDomainAndRemovesOnlyItsOwn()
    {
        Assert.Empty(Sync(Alice, ("corp.example", "10.0.0.1"), ("lan", "10.0.0.1")));
        Assert.Equal([".corp.example"], _nrpt.Nrpt["WireTunnels-corp.example"].Names);
        Assert.Equal(["10.0.0.1"], _nrpt.Nrpt["WireTunnels-lan"].Servers);

        Assert.Equal(["corp.example"], Sync(Bob, ("corp.example", "10.9.9.9"))); // Alice's rule is not Bob's
        Assert.Equal(SplitDns.Marker(Alice), _nrpt.Nrpt["WireTunnels-corp.example"].Comment);

        Assert.Empty(Sync(Alice, ("lan", "10.0.0.1")));
        Assert.False(_nrpt.Nrpt.ContainsKey("WireTunnels-corp.example"));
        Assert.Empty(Sync(Alice));
        Assert.Empty(_nrpt.Nrpt);
    }

    [Fact]
    public void ForeignRulesAreConflictsAndStayUntouched()
    {
        _nrpt.Nrpt["{GUID}"] = new NrptRule([".corp.example"], ["172.16.0.1"], "");
        Assert.Equal(["corp.example"], Sync(Alice, ("corp.example", "10.0.0.1")));
        Assert.Empty(Sync(Alice));
        Assert.Equal(["{GUID}"], _nrpt.Nrpt.Keys);
    }

    [Fact]
    public void GroupPolicyNrptIsReported()
    {
        _nrpt.PolicyManaged = true;
        Assert.Throws<InvalidOperationException>(() => Sync(Alice, ("lan", "10.0.0.1")));
        Assert.Empty(Sync(Alice)); // clearing still works
    }

    [Theory]
    [InlineData("corp.example", true)]
    [InlineData("lan", true)]
    [InlineData(".lan", false)]
    [InlineData("lan.", false)]
    [InlineData("-lan", false)]
    [InlineData("a..b", false)]
    [InlineData("Corp.example", false)]
    [InlineData("corp example", false)]
    [InlineData("", false)]
    public void DomainValidationMatchesTheMacOSHelper(string domain, bool valid) => Assert.Equal(valid, SplitDns.IsValidDomain(domain));
}

public class NetworkDispatcherTests
{
    private static readonly ClientIdentity Alice = new("S-1-5-21-1-1001", "alice", false);
    private static readonly ClientIdentity Bob = new("S-1-5-21-1-1002", "bob", false);
    private readonly FakeBackend _backend = new();
    private readonly NetworkFakes _net = new();
    private readonly RequestDispatcher _d;

    public NetworkDispatcherTests() => _d = _net.Dispatcher(_backend);

    private Task<Response> Call(ClientIdentity who, string op, object args) =>
        _d.HandleAsync(new Request { Id = 1, Op = op, Args = JsonSerializer.SerializeToNode(args, Protocol.Json)!.AsObject() }, who, default);

    private static string Config() => $"""
        [Interface]
        PrivateKey = {WireGuardKey.Generate().PrivateKey}
        Address = 10.0.0.2/32
        [Peer]
        PublicKey = {WireGuardKey.Generate().PublicKey}
        AllowedIPs = 0.0.0.0/0
        """;

    private Task<Response> Start(ClientIdentity who, string name, bool suppressDns = false) =>
        Call(who, Ops.StartTunnel, new StartTunnelArgs { Name = name, Contents = Config(), SuppressDns = suppressDns });

    private static SyncKillSwitchArgs KillSwitch(string name, string host = "198.51.100.1", int port = 51820) =>
        new() { Entries = [new KillSwitchEntry { Name = name, EndpointHost = host, EndpointPort = port }] };

    [Fact]
    public async Task KillSwitchEntriesAreValidated()
    {
        Assert.Equal("Invalid tunnel name", (await Call(Alice, Ops.SyncKillSwitch, KillSwitch("../x"))).Error);
        Assert.Equal("Invalid kill switch endpoint", (await Call(Alice, Ops.SyncKillSwitch, KillSwitch("office", "vpn.example.com"))).Error);
        Assert.Equal("Invalid kill switch endpoint", (await Call(Alice, Ops.SyncKillSwitch, KillSwitch("office", "010.0.0.1"))).Error);
        Assert.Equal("Invalid kill switch endpoint port", (await Call(Alice, Ops.SyncKillSwitch, KillSwitch("office", port: 0))).Error);
        Assert.Equal(0, _net.KillSwitchWrites);
    }

    [Fact]
    public async Task AUserCannotArmAnotherUsersRunningTunnel()
    {
        await Start(Alice, "office");
        Assert.False((await Call(Bob, Ops.SyncKillSwitch, KillSwitch("office"))).Ok);
        Assert.True((await Call(Alice, Ops.SyncKillSwitch, KillSwitch("office"))).Ok);
        Assert.Equal(_backend.Luid("office"), Assert.Single(_net.KillSwitch).Luid);

        // Stopping and restarting the tunnel moves the permit to the new adapter.
        await Call(Alice, Ops.StopTunnel, new TunnelNameArgs { Name = "office" });
        Assert.Null(Assert.Single(_net.KillSwitch).Luid);
        await Start(Alice, "office");
        Assert.Equal(_backend.Luid("office"), Assert.Single(_net.KillSwitch).Luid);
    }

    [Fact]
    public async Task RoutesThroughATunnelNeedItsOwner()
    {
        await Start(Alice, "hop", suppressDns: true);
        Assert.Equal(["hop"], _backend.SuppressedDns);
        var args = new SyncRoutesArgs { OwnerId = Guid.NewGuid(), Entries = [new RouteEntry { Cidr = "203.0.113.5/32", Tunnel = "hop" }] };
        Assert.Equal("hop is not one of your connected tunnels", (await Call(Bob, Ops.SyncRoutes, args)).Error);
        Assert.True((await Call(Alice, Ops.SyncRoutes, args)).Ok);
        Assert.Single(_net.Routes);

        Assert.Equal("Invalid route owner", (await Call(Alice, Ops.SyncRoutes, new SyncRoutesArgs())).Error);
        Assert.Equal("Invalid route CIDR: 10.0.0.1",
            (await Call(Alice, Ops.SyncRoutes, new SyncRoutesArgs { OwnerId = Guid.NewGuid(), Entries = [new RouteEntry { Cidr = "10.0.0.1" }] })).Error);
    }

    [Fact]
    public async Task SplitDnsRequestsAreValidatedAndConflictsReported()
    {
        static SyncSplitDnsArgs Args(string domain, string server) =>
            new() { Entries = [new SplitDnsEntry { OwnerId = "x", Domains = [domain], Servers = [server] }] };
        Assert.Equal("Invalid split DNS domain: ../etc", (await Call(Alice, Ops.SyncSplitDns, Args("../etc", "10.0.0.1"))).Error);
        Assert.Equal("Invalid split DNS server: dns.example", (await Call(Alice, Ops.SyncSplitDns, Args("lan", "dns.example"))).Error);
        Assert.True((await Call(Alice, Ops.SyncSplitDns, Args("lan", "10.0.0.1"))).Ok);
        Assert.Equal("Existing DNS rules for lan were left untouched", (await Call(Bob, Ops.SyncSplitDns, Args("lan", "10.0.0.2"))).Error);
    }
}
