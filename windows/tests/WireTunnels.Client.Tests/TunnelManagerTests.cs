using System.Text.Json;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;

namespace WireTunnels.Client.Tests;

public class TunnelManagerTests : IDisposable
{
    private readonly Harness _h = new();
    private TunnelManager M => _h.Manager;

    public void Dispose() => _h.Dispose();

    private async Task<TunnelManager> Ready()
    {
        await M.InitializeAsync();
        Assert.Equal(SetupState.Ready, M.SetupState);
        return M;
    }

    [Fact]
    public async Task CreatedConfigIsEncryptedAndKeyedByAlias()
    {
        await Ready();
        var config = Harness.Config();
        var tunnel = M.Create("Office VPN", config);

        Assert.Equal("Office VPN", tunnel.Name);
        Assert.Equal(Path.Combine(_h.Configs.Directory, ConfigName.FileBaseName("Office VPN") + ConfigStore.Extension), tunnel.ConfigPath);
        Assert.DoesNotContain("PrivateKey", Harness.Text(File.ReadAllBytes(tunnel.ConfigPath)));
        Assert.Equal(config, M.ReadConfig(tunnel.Id));
        Assert.Equal(["10.0.0.0/24"], tunnel.AllowedIPs);
        Assert.Equal(WireGuardKey.PublicKey(WireGuardConfig.Parse(config).PrivateKey!), tunnel.LocalPublicKey);

        // Same JSON shape as macOS tunnels.json.
        var json = JsonDocument.Parse(File.ReadAllText(_h.Paths.TunnelsFile)).RootElement[0];
        Assert.Equal("Office VPN", json.GetProperty("name").GetString());
        Assert.False(json.GetProperty("isFavorite").GetBoolean());
        Assert.Equal("personal", json.GetProperty("scope").GetString());
    }

    [Fact]
    public async Task NamesSharingAnAliasCollide()
    {
        await Ready();
        M.Create("office", Harness.Config());
        var e = Assert.Throws<ConfigStorageException>(() => M.Create("office", Harness.Config()));
        Assert.Contains("already exists", e.Message);
        Assert.Single(M.Tunnels);
    }

    [Fact]
    public async Task InvalidConfigIsRejectedWithoutSavingAnything()
    {
        await Ready();
        Assert.Throws<ConfigValidationException>(() => M.Create("bad", Harness.Config(extra: "PostUp = calc.exe")));
        Assert.Empty(M.Tunnels);
        Assert.False(Directory.Exists(_h.Configs.Directory) && Directory.EnumerateFiles(_h.Configs.Directory).Any());
    }

    [Fact]
    public async Task ConnectStartsTheAliasAndMergesRuntimeStatus()
    {
        await Ready();
        var tunnel = M.Create("Office VPN", Harness.Config());
        _h.Service.Rx = 5000;
        _h.Service.Tx = 1000;

        await M.ConnectAsync(tunnel.Id);

        var alias = ConfigName.FileBaseName("Office VPN");
        Assert.Equal([$"start {alias}"], _h.Service.Calls);
        Assert.True(tunnel.IsActive);
        Assert.Equal(alias, tunnel.InterfaceName);
        Assert.Equal((5000, 1000), (tunnel.RxBytes, tunnel.TxBytes));
        Assert.Equal("198.51.100.1:51820", tunnel.Endpoint);
        Assert.Null(M.ConnectionStatusOf(tunnel.Id));
        Assert.Equal(ConnectionStatus.Connected, M.TrayStatus);
        Assert.Null(M.ErrorMessage);
        Assert.Equal(["Tunnel Connected: Office VPN connected successfully."], _h.Notifier.Posted);
    }

    [Fact]
    public async Task TrafficRatesComeFromSuccessiveSnapshots()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        await M.ConnectAsync(tunnel.Id);
        _h.Time.Advance(2);
        _h.Service.Rx = 2000;
        _h.Service.Tx = 400;
        await M.RefreshStatusAsync();

        var sample = Assert.Single(M.TrafficOf(tunnel.Id));
        Assert.Equal((1000, 200), (sample.RxRate, sample.TxRate));
    }

    [Fact]
    public async Task FailedConnectAlertsOnlyForUserActions()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        _h.Service.FailStart = new ServiceException("Unable to create adapter office");

        await M.ConnectAsync(tunnel.Id, automatic: true);
        Assert.Null(M.ErrorMessage);
        Assert.Empty(_h.Notifier.Posted);
        Assert.Equal(ConnectionStatus.ConnectionLost, M.ConnectionStatusOf(tunnel.Id));

        await M.ConnectAsync(tunnel.Id);
        Assert.Equal("Failed to connect office: Unable to create adapter office", M.ErrorMessage);
        Assert.Single(_h.Notifier.Posted);
        Assert.False(tunnel.IsActive);
    }

    [Fact]
    public async Task UnexpectedDropIsReportedAsConnectionLostThenRecovers()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        await M.ConnectAsync(tunnel.Id);
        var contents = _h.Service.Running["office"];

        _h.Service.Running.Clear(); // e.g. the service restarted
        await M.RefreshStatusAsync();
        Assert.False(tunnel.IsActive);
        Assert.Null(tunnel.InterfaceName);
        Assert.Equal(ConnectionStatus.ConnectionLost, M.ConnectionStatusOf(tunnel.Id));
        Assert.Equal(ConnectionStatus.ConnectionLost, M.TrayStatus);

        _h.Service.Running["office"] = contents; // started again, e.g. from the CLI
        await M.RefreshStatusAsync();
        Assert.True(tunnel.IsActive);
        Assert.Null(M.ConnectionStatusOf(tunnel.Id));
    }

    [Fact]
    public async Task StatusFailurePreservesStateAndAlertsOnce()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        await M.ConnectAsync(tunnel.Id);
        _h.Service.FailStatus = new ServiceException("Lost the connection to the WireTunnels service.");

        Assert.False(await M.RefreshStatusAsync());
        Assert.True(tunnel.IsActive);
        Assert.StartsWith("Unable to refresh tunnel status", M.ErrorMessage);
        M.ErrorMessage = null;
        Assert.False(await M.RefreshStatusAsync());
        Assert.Null(M.ErrorMessage); // reported once until the service answers again
    }

    [Fact]
    public async Task DisconnectStopsTheRunningAliasAndClearsRuntimeState()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        await M.ConnectAsync(tunnel.Id);

        Assert.True(await M.DisconnectAsync(tunnel.Id));
        Assert.Contains("stop office", _h.Service.Calls);
        Assert.False(tunnel.IsActive);
        Assert.Equal((0, 0), (tunnel.RxBytes, tunnel.TxBytes));
        Assert.Null(tunnel.ConnectedAt);
        Assert.Empty(M.TrafficOf(tunnel.Id));
        Assert.Equal(ConnectionStatus.Idle, M.TrayStatus);
    }

    [Fact]
    public async Task RenamingAConnectedTunnelKeepsTheRunningAdapterUntilReconnect()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        await M.ConnectAsync(tunnel.Id);
        var oldPath = tunnel.ConfigPath;

        var edited = Harness.Config("10.1.0.0/16");
        M.Update(tunnel.Id, "office2", edited);

        var live = M.Find(tunnel.Id)!;
        Assert.Equal("office2", live.Name);
        Assert.False(File.Exists(oldPath));
        Assert.Equal(edited, M.ReadConfig(tunnel.Id));
        Assert.True(live.IsActive);
        Assert.Equal("office", live.InterfaceName);

        await M.RefreshStatusAsync();
        Assert.True(M.Find(tunnel.Id)!.IsActive); // still matched by the old adapter name
        Assert.True(await M.DisconnectAsync(tunnel.Id));
        Assert.Contains("stop office", _h.Service.Calls);
    }

    [Fact]
    public async Task DuplicateCreatesDisconnectedNumberedCopies()
    {
        await Ready();
        var source = M.Create("office", Harness.Config());
        source.AutoConnectRule.Connect.Enabled = true;
        source.SpeedTestURL = "https://example.com/file";

        var first = M.Duplicate(source.Id);
        var second = M.Duplicate(source.Id);

        Assert.Equal("office_copy", first.Name);
        Assert.Equal("office_copy_2", second.Name);
        Assert.False(first.AutoConnectRule.Connect.Enabled);
        Assert.Equal("https://example.com/file", first.SpeedTestURL);
        Assert.Equal(M.ReadConfig(source.Id), M.ReadConfig(first.Id));
        Assert.False(first.IsActive);
        Assert.Equal(3, M.Tunnels.Count);
    }

    [Fact]
    public async Task DeleteRefusesConnectedTunnelsAndRemovesTheConfig()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        await M.ConnectAsync(tunnel.Id);

        M.Delete(tunnel.Id);
        Assert.Equal("Disconnect office before deleting it.", M.ErrorMessage);
        Assert.Single(M.Tunnels);

        await M.DisconnectAsync(tunnel.Id);
        M.Delete(tunnel.Id);
        Assert.Empty(M.Tunnels);
        Assert.False(File.Exists(tunnel.ConfigPath));
    }

    [Fact]
    public async Task StateSurvivesARestartOfTheApp()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        M.ToggleFavorite(tunnel.Id);
        await M.ConnectAsync(tunnel.Id);

        var restarted = _h.NewManager();
        await restarted.InitializeAsync();
        var loaded = Assert.Single(restarted.Tunnels);
        Assert.True(loaded.IsFavorite);
        Assert.True(loaded.IsActive); // the service kept the tunnel running while the app was closed
    }

    [Fact]
    public async Task ATunnelGoneWhileTheAppWasClosedIsNotReportedAsLost()
    {
        await Ready();
        var tunnel = M.Create("office", Harness.Config());
        await M.ConnectAsync(tunnel.Id);
        _h.Service.Running.Clear(); // e.g. the PC rebooted

        var restarted = _h.NewManager();
        await restarted.InitializeAsync();
        var loaded = Assert.Single(restarted.Tunnels);
        Assert.False(loaded.IsActive);
        Assert.Null(restarted.ConnectionStatusOf(loaded.Id));
        Assert.Equal(ConnectionStatus.Idle, restarted.TrayStatus);
        var again = _h.NewManager();
        await again.InitializeAsync();
        Assert.False(again.Tunnels.Single().IsActive); // the reconciled state was saved
    }

    [Theory]
    [InlineData(ServiceInstallState.NotInstalled, SetupState.ServiceMissing)]
    [InlineData(ServiceInstallState.Stopped, SetupState.ServiceStopped)]
    [InlineData(ServiceInstallState.Starting, SetupState.ServiceStarting)]
    public async Task SetupStateFollowsTheWindowsService(ServiceInstallState installed, SetupState expected)
    {
        _h.Probe.State = installed;
        await M.InitializeAsync();
        Assert.Equal(expected, M.SetupState);
        Assert.True(M.NeedsSetup);
        Assert.False(M.CanConnectTunnels);

        var tunnel = M.Create("office", Harness.Config());
        await M.ConnectAsync(tunnel.Id);
        Assert.Empty(_h.Service.Calls);
        Assert.Equal(M.ConnectionUnavailableReason, M.ErrorMessage);
    }

    [Fact]
    public async Task AServiceOfAnotherVersionIsReportedAsIncompatible()
    {
        _h.Service.FailHandshake = new ServiceProtocolException("The WireTunnels service speaks protocol 2, this app needs 1. Reinstall WireTunnels.");
        await M.InitializeAsync();
        Assert.Equal(SetupState.Incompatible, M.SetupState);
        Assert.Contains("protocol 2", M.ConnectionUnavailableReason);
    }

    [Fact]
    public async Task QuitDisconnectsEverythingFirst()
    {
        await Ready();
        var a = M.Create("a", Harness.Config());
        var b = M.Create("b", Harness.Config("10.9.0.0/24"));
        await M.ConnectAsync(a.Id);
        await M.ConnectAsync(b.Id);

        Assert.True(await M.PrepareForQuitAsync());
        Assert.Empty(_h.Service.Running);
        Assert.False(M.HasActiveTunnels);
        Assert.True(M.IsShuttingDown);
    }

    [Fact]
    public async Task QuitStopsWhenATunnelCannotBeDisconnectedAndCanBeCancelled()
    {
        await Ready();
        var a = M.Create("a", Harness.Config());
        await M.ConnectAsync(a.Id);
        _h.Service.FailStop = new ServiceException("busy");

        Assert.False(await M.PrepareForQuitAsync());
        Assert.Equal("One or more tunnels could not be disconnected.", M.QuitFailureReason);

        await M.CancelQuitAsync();
        Assert.False(M.IsShuttingDown);
        Assert.Null(M.QuitFailureReason);
        Assert.True(M.CanConnectTunnels);
    }

    [Fact]
    public async Task QuitRefusesToLeaveAnUnknownTunnelRunning()
    {
        await Ready();
        _h.Service.Running["cli-only"] = Harness.Config();
        Assert.False(await M.PrepareForQuitAsync());
        Assert.Contains("cli-only", M.ErrorMessage);
        Assert.Equal("Unable to confirm the current tunnel state.", M.QuitFailureReason);
    }

    [Fact]
    public async Task QuitWithTheServiceStoppedHasNothingToDisconnect()
    {
        await Ready();
        var a = M.Create("a", Harness.Config());
        await M.ConnectAsync(a.Id);
        _h.Probe.State = ServiceInstallState.Stopped; // stopping the service removed every adapter

        Assert.True(await M.PrepareForQuitAsync());
        Assert.False(a.IsActive);
    }

    [Fact]
    public async Task WarningsFollowActiveTunnels()
    {
        await Ready();
        var a = M.Create("a", Harness.Config("0.0.0.0/0"));
        var b = M.Create("b", Harness.Config("0.0.0.0/0"));
        await M.ConnectAsync(a.Id);
        await M.ConnectAsync(b.Id);
        Assert.Contains(M.Warnings, w => w.Kind == Core.Models.TunnelWarningKind.MultipleFullTunnels);

        await M.DisconnectAsync(b.Id);
        Assert.Empty(M.Warnings);
    }

    [Fact]
    public async Task NotificationsCanBeTurnedOff()
    {
        await Ready();
        _h.NotificationsEnabled = false;
        var a = M.Create("a", Harness.Config());
        await M.ConnectAsync(a.Id);
        await M.DisconnectAsync(a.Id);
        Assert.Empty(_h.Notifier.Posted);
    }
}
