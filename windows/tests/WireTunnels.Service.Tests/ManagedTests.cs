using System.Text.Json;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Service.Ipc;

namespace WireTunnels.Service.Tests;

/// Shared tunnels (phase 5): the HelperTool managed ops and the logoff cleanup.
public class ManagedDispatcherTests
{
    private static readonly ClientIdentity Alice = new("S-1-5-21-1-1001", "alice", false, SessionId: 1);
    private static readonly ClientIdentity Bob = new("S-1-5-21-1-1002", "bob", false, SessionId: 2);
    private static readonly ClientIdentity Admin = new("S-1-5-21-1-500", "admin", true, SessionId: 2);
    private static readonly string PrivateKey = WireGuardKey.Generate().PrivateKey;

    private readonly FakeBackend _backend = new();
    private readonly NetworkFakes _net = new();
    private readonly RequestDispatcher _d;

    public ManagedDispatcherTests() => _d = _net.Dispatcher(_backend);

    private static string Config(string extra = "") => $"""
        [Interface]
        PrivateKey = {PrivateKey}
        Address = 10.9.0.2/32
        DNS = 10.9.0.1
        {extra}
        [Peer]
        PublicKey = {WireGuardKey.Generate().PublicKey}
        Endpoint = 198.51.100.9:51820
        AllowedIPs = 10.9.0.0/24
        """;

    private Task<Response> Call(ClientIdentity who, string op, object? args = null) =>
        _d.HandleAsync(new Request { Id = 1, Op = op, Args = args is null ? null : JsonSerializer.SerializeToNode(args, Protocol.Json)!.AsObject() }, who, default);

    private async Task<Tunnel> Install(string name = "Office VPN")
    {
        var r = await Call(Admin, Ops.InstallManaged, new InstallManagedArgs { Name = name, Contents = Config() });
        Assert.True(r.Ok, r.Error);
        return r.Data.Deserialize<Tunnel>(Protocol.Json)!;
    }

    private Task<Response> Update(Tunnel t, ManagedTunnelPolicy policy, string? contents = null, string? name = null) =>
        Call(Admin, Ops.UpdateManaged, new UpdateManagedArgs { Id = t.Id, Name = name ?? t.Name, Contents = contents, Policy = policy });

    private Task<Response> StartShared(ClientIdentity who, Tunnel t) => Call(who, Ops.StartManaged, new ManagedIdArgs { Id = t.Id });

    private async Task<List<string>> Visible(ClientIdentity who) =>
        (await Call(who, Ops.RuntimeStatusSnapshot)).Data.Deserialize<List<TunnelRuntimeStatus>>(Protocol.Json)!.Select(s => s.Name).ToList();

    [Fact]
    public async Task OnlyAnElevatedAdminCanChangeOrReadSharedTunnels()
    {
        var t = await Install();
        var id = new ManagedIdArgs { Id = t.Id };
        foreach (var (op, args) in new (string, object)[]
        {
            (Ops.InstallManaged, new InstallManagedArgs { Name = "x", Contents = Config() }),
            (Ops.ReadManaged, id), (Ops.DeleteManaged, id), (Ops.ListManagedUsers, id),
            (Ops.UpdateManaged, new UpdateManagedArgs { Id = t.Id, Name = "x" }),
            (Ops.SetSystemSettings, new SystemSettings { RequireAdminToDisableLaunchAtLogin = true }),
        })
            Assert.StartsWith("Only an administrator", (await Call(Alice, op, args)).Error);
        Assert.Single(_net.Managed.Records);
        Assert.False(_net.Managed.Settings.RequireAdminToDisableLaunchAtLogin);
    }

    [Fact]
    public async Task UsersSeeSanitizedMetadataAndAdminsTheConfig()
    {
        var t = await Install();
        Assert.Equal(TunnelScope.Managed, t.Scope);
        Assert.Equal(ConfigName.FileBaseName("Office VPN"), t.ConfigPath); // the adapter alias
        Assert.Equal(["10.9.0.1"], t.Dns);
        Assert.Equal(WireGuardKey.PublicKey(PrivateKey), t.LocalPublicKey);

        var list = await Call(Alice, Ops.ListManaged);
        Assert.DoesNotContain(PrivateKey, list.Data!.ToJsonString());
        Assert.Equal(t.Id, Assert.Single(list.Data.Deserialize<List<Tunnel>>(Protocol.Json)!).Id);
        Assert.Contains(PrivateKey, (await Call(Admin, Ops.ReadManaged, new ManagedIdArgs { Id = t.Id })).Data!.GetValue<string>());

        Assert.Equal("A shared tunnel named office vpn already exists",
            (await Call(Admin, Ops.InstallManaged, new InstallManagedArgs { Name = "office vpn", Contents = Config() })).Error);
        Assert.Contains("PostUp", (await Call(Admin, Ops.InstallManaged, new InstallManagedArgs { Name = "hooked", Contents = Config("PostUp = calc") })).Error);
    }

    [Fact]
    public async Task ASharedTunnelIsMachineWideAndFollowsItsPolicy()
    {
        var t = await Install();
        Assert.True((await StartShared(Alice, t)).Ok);
        Assert.Contains(t.ConfigPath, _backend.Running);
        Assert.Equal([t.ConfigPath], await Visible(Bob));
        Assert.True((await StartShared(Bob, t)).Ok); // joins the running tunnel

        var users = (await Call(Admin, Ops.ListManagedUsers, new ManagedIdArgs { Id = t.Id })).Data.Deserialize<List<ManagedTunnelUserSession>>(Protocol.Json)!;
        Assert.Equal(["alice", "bob"], users.Select(u => u.Username));

        Assert.True((await Update(t, new ManagedTunnelPolicy { UsersCanDisconnect = false })).Ok);
        Assert.Equal("Users are not allowed to disconnect this shared tunnel", (await Call(Bob, Ops.StopTunnel, new TunnelNameArgs { Name = t.ConfigPath })).Error);
        Assert.Equal("Disconnect the shared tunnel before deleting it", (await Call(Admin, Ops.DeleteManaged, new ManagedIdArgs { Id = t.Id })).Error);
        Assert.Equal("Disconnect the shared tunnel before changing its name or configuration",
            (await Update(t, new ManagedTunnelPolicy(), contents: Config())).Error);

        Assert.True((await Call(Admin, Ops.StopTunnel, new TunnelNameArgs { Name = t.ConfigPath })).Ok);
        Assert.Empty(_backend.Running);
        Assert.Empty((await Call(Admin, Ops.ListManagedUsers, new ManagedIdArgs { Id = t.Id })).Data!.AsArray());

        Assert.True((await Update(t, new ManagedTunnelPolicy { UsersCanConnect = false })).Ok);
        Assert.Equal("Users are not allowed to connect this shared tunnel", (await StartShared(Alice, t)).Error);
        Assert.True((await Call(Admin, Ops.DeleteManaged, new ManagedIdArgs { Id = t.Id })).Ok);
        Assert.Empty(_net.Managed.Records);
        Assert.Empty(_net.Managed.Configs);
    }

    [Fact]
    public async Task SplitDnsPolicyKeepsDnsOffTheAdapterAndIsValidated()
    {
        var t = await Install();
        Assert.Equal("Invalid split DNS domain: ../x", (await Update(t, new ManagedTunnelPolicy { SplitDNSDomains = ["../x"] })).Error);
        Assert.True((await Update(t, new ManagedTunnelPolicy { SplitDNSDomains = ["corp.example"] })).Ok);
        await StartShared(Alice, t);
        Assert.Equal([t.ConfigPath], _backend.SuppressedDns);
        Assert.Equal("10.9.0.1", Assert.Single(_net.Nrpt).Value.Servers.Single()); // applied by the service, not per user
        await Call(Alice, Ops.StopTunnel, new TunnelNameArgs { Name = t.ConfigPath });
        Assert.Empty(_net.Nrpt);
    }

    [Fact]
    public async Task APersonalTunnelCannotTakeASharedTunnelsName()
    {
        var t = await Install();
        var r = await Call(Admin, Ops.StartTunnel, new StartTunnelArgs { Name = t.ConfigPath, Contents = Config() });
        Assert.Equal("A shared tunnel already uses this name", r.Error);
    }

    [Fact]
    public async Task AnyUserCanArmTheKillSwitchOfARunningSharedTunnel()
    {
        var t = await Install();
        await StartShared(Alice, t);
        var args = new SyncKillSwitchArgs { Entries = [new KillSwitchEntry { Name = t.ConfigPath, EndpointHost = "198.51.100.9", EndpointPort = 51820 }] };
        Assert.True((await Call(Bob, Ops.SyncKillSwitch, args)).Ok);
    }

    [Fact]
    public async Task LogoffStopsTheUsersTunnelsAndPolicyLikeAQuitOnMacOS()
    {
        var shared = await Install();
        await StartShared(Alice, shared);
        await Call(Alice, Ops.StartTunnel, new StartTunnelArgs { Name = "home", Contents = Config() });
        await Call(Alice, Ops.SyncKillSwitch, new SyncKillSwitchArgs { Entries = [new KillSwitchEntry { Name = "home", EndpointHost = "198.51.100.9", EndpointPort = 51820 }] });
        await Call(Bob, Ops.StartTunnel, new StartTunnelArgs { Name = "bobs", Contents = Config() });
        Assert.NotEmpty(_net.KillSwitch);

        await _d.SessionLoggedOffAsync(1);
        Assert.Equal(["bobs"], _backend.Running);
        Assert.Empty(_net.KillSwitch);

        // A shared tunnel users may not disconnect survives the logoff, as it refuses the quit on macOS.
        Assert.True((await Update(shared, new ManagedTunnelPolicy { UsersCanDisconnect = false })).Ok);
        await StartShared(Alice, shared);
        await _d.SessionLoggedOffAsync(1);
        Assert.Contains(shared.ConfigPath, _backend.Running);
        Assert.Empty((await Call(Admin, Ops.ListManagedUsers, new ManagedIdArgs { Id = shared.Id })).Data!.AsArray());

        // A user still logged on in another session keeps everything.
        await Call(Bob with { SessionId = 3 }, Ops.RuntimeStatusSnapshot);
        await _d.SessionLoggedOffAsync(2);
        Assert.Contains("bobs", _backend.Running);
        await _d.SessionLoggedOffAsync(3);
        Assert.DoesNotContain("bobs", _backend.Running);
    }
}
