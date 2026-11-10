using WireTunnels.Contracts;
using WireTunnels.Core.Models;

namespace WireTunnels.Client.Tests;

/// Phase 5 in the app: shared tunnels come from the service and connect by id.
public class SharedTunnelTests : IDisposable
{
    private readonly Harness _h = new();
    private TunnelManager M => _h.Manager;

    public void Dispose() => _h.Dispose();

    private async Task<Tunnel> SharedOffice()
    {
        await _h.Service.AdminAsync<Tunnel>(Ops.InstallManaged, new InstallManagedArgs { Name = "office", Contents = Harness.Config() });
        _h.Service.AdminCalls.Clear();
        await M.InitializeAsync();
        return Assert.Single(M.SharedTunnels);
    }

    [Fact]
    public async Task SharedTunnelsConnectThroughTheServiceAndMatchItsStatus()
    {
        var shared = await SharedOffice();
        await M.ConnectAsync(shared.Id);
        Assert.Contains("start shared office", _h.Service.Calls);
        Assert.DoesNotContain("start office", _h.Service.Calls);
        Assert.True(M.Find(shared.Id)!.IsActive);

        // A refresh of the shared list keeps the runtime state.
        await M.LoadManagedTunnelsAsync();
        Assert.True(M.Find(shared.Id)!.IsActive);

        Assert.True(await M.DisconnectAsync(shared.Id));
        Assert.DoesNotContain("office", _h.Service.Running.Keys);
    }

    [Fact]
    public async Task SplitDnsOfASharedTunnelIsLeftToTheService()
    {
        var shared = await SharedOffice();
        _h.Service.Managed[0].ManagedPolicy = new ManagedTunnelPolicy { SplitDNSDomains = ["corp.example"] };
        await M.LoadManagedTunnelsAsync();
        await M.ConnectAsync(shared.Id);
        Assert.Empty(_h.Service.SplitDns);
    }

    [Fact]
    public async Task QuitDisconnectsSharedTunnelsLikeMacOS()
    {
        var shared = await SharedOffice();
        var personal = M.Create("home", Harness.Config());
        await M.ConnectAsync(shared.Id);
        await M.ConnectAsync(personal.Id);
        Assert.True(await M.PrepareForQuitAsync());
        Assert.Empty(_h.Service.Running);
    }

    [Fact]
    public async Task QuitFailsWhileASharedTunnelMayNotBeDisconnected()
    {
        var shared = await SharedOffice();
        await M.ConnectAsync(shared.Id);
        _h.Service.Managed[0].ManagedPolicy = new ManagedTunnelPolicy { UsersCanDisconnect = false };
        await M.LoadManagedTunnelsAsync();
        Assert.False(await M.PrepareForQuitAsync());
        Assert.Equal("One or more tunnels could not be disconnected.", M.QuitFailureReason);
        Assert.Contains("office", _h.Service.Running.Keys);
    }

    [Fact]
    public async Task MakeSharedMovesThePersonalTunnelToTheService()
    {
        await M.InitializeAsync();
        var config = Harness.Config();
        var personal = M.Create("lab", config);
        await M.MakeSharedAsync(personal.Id);

        Assert.Equal([Ops.InstallManaged], _h.Service.AdminCalls);
        Assert.Equal(config, _h.Service.ManagedConfigs.Values.Single());
        Assert.Null(M.Find(personal.Id));
        Assert.False(File.Exists(personal.ConfigPath));
        Assert.Equal("lab", Assert.Single(M.SharedTunnels).Name);
    }

    [Fact]
    public async Task ImportSharedGoesStraightToTheServiceWithoutAPersonalCopy()
    {
        await M.InitializeAsync();
        var config = Harness.Config();
        var shared = await M.ImportSharedAsync("lab", config);

        Assert.Equal([Ops.InstallManaged], _h.Service.AdminCalls);
        Assert.Equal(config, _h.Service.ManagedConfigs.Values.Single());
        Assert.Empty(M.Tunnels.Where(t => t.Scope == TunnelScope.Personal));
        Assert.Equal(shared.Id, Assert.Single(M.SharedTunnels).Id);
        await Assert.ThrowsAsync<ConfigValidationException>(() => M.ImportSharedAsync("bad", "[Interface]"));
        Assert.Single(_h.Service.AdminCalls);
    }

    [Fact]
    public async Task MakeSharedKeepsThePersonalTunnelWhenTheAdminPromptIsDeclined()
    {
        await M.InitializeAsync();
        var personal = M.Create("lab", Harness.Config());
        _h.Service.FailAdmin = new ServiceException("The administrator prompt was declined.");
        await Assert.ThrowsAsync<ServiceException>(() => M.MakeSharedAsync(personal.Id));
        Assert.NotNull(M.Find(personal.Id));
        Assert.True(File.Exists(personal.ConfigPath));
    }

    [Fact]
    public async Task PolicyChangesGoToTheServiceAndArmTheKillSwitch()
    {
        var shared = await SharedOffice();
        await M.ConnectAsync(shared.Id);
        await M.UpdateManagedPolicyAsync(shared.Id, new ManagedTunnelPolicy { KillSwitchEnabled = true, SplitDNSDomains = ["Corp.Example.", "corp.example"] });
        Assert.Equal([Ops.UpdateManaged], _h.Service.AdminCalls);
        Assert.Equal(["corp.example"], _h.Service.Managed[0].ManagedPolicy!.SplitDNSDomains);
        Assert.True(M.IsKillSwitchArmed(shared.Id));
        Assert.Equal("office", Assert.Single(_h.Service.KillSwitch).Name);

        await M.UpdateManagedPolicyAsync(shared.Id, new ManagedTunnelPolicy());
        Assert.False(M.IsKillSwitchArmed(shared.Id));
    }

    [Fact]
    public async Task LaunchAtLoginNeedsAnAdminOnlyWhenRequired()
    {
        await M.InitializeAsync();
        Assert.True(await M.AuthorizeDisablingLaunchAtLoginAsync());
        Assert.Empty(_h.Service.AdminCalls);

        await M.SetRequireAdminToDisableLaunchAtLoginAsync(true);
        Assert.True(M.SystemSettings.RequireAdminToDisableLaunchAtLogin);
        _h.Service.FailAdmin = new ServiceException("The administrator prompt was declined.");
        Assert.False(await M.AuthorizeDisablingLaunchAtLoginAsync());
    }
}
