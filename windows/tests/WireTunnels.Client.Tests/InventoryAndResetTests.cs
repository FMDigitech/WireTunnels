using System.Diagnostics;
using WireTunnels.Contracts;
using WireTunnels.Core.Models;
using ZXing;
using ZXing.Common;

namespace WireTunnels.Client.Tests;

/// The app side of Inventory AllowedIPs (TunnelInventoryIntegration.swift), against the fake service.
public class InventoryClientTests : IDisposable
{
    private readonly Harness _h = new();
    private TunnelManager M => _h.Manager;
    private FakeTunnelService S => _h.Service;
    // Any existing file passes the "absolute path to an executable" check.
    private static readonly InventoryCommand Command = new() { Executable = Environment.ProcessPath!, Arguments = ["--list"] };

    public void Dispose() => _h.Dispose();

    private async Task<Tunnel> Ready()
    {
        await M.InitializeAsync();
        return M.Create("office", Harness.Config(allowed: "192.0.2.0/24"));
    }

    private string[] InventoryCalls() => [.. S.Calls.Where(c => c.StartsWith("inventory") || c.StartsWith("start") || c.StartsWith("stop")).Select(c => c.Split(' ')[0] + " " + c.Split(' ')[1] + (c.EndsWith("cached") ? " cached" : ""))];

    [Fact]
    public async Task SettingACommandProtectsAtOnceAndIsSaved()
    {
        var tunnel = await Ready();
        await M.UpdateInventoryCommandAsync(tunnel.Id, Command);
        var request = Assert.Single(S.Inventory);
        Assert.Equal(InventoryAction.Protect, request.Action);
        Assert.Equal(["192.0.2.0/24"], request.StaticPrefixes);
        Assert.Equal(("198.51.100.1", 51820), (request.EndpointHost, request.EndpointPort));
        Assert.Equal(tunnel.InterfaceName ?? request.Name, request.Name);
        Assert.Equal(Command.Executable, tunnel.InventoryCommand!.Executable);
        Assert.Contains("\"inventoryCommand\"", File.ReadAllText(_h.Paths.TunnelsFile));
    }

    [Fact]
    public async Task CommandsAreRefusedWhileConnectedOrCombinedWithExclusions()
    {
        var tunnel = await Ready();
        await Assert.ThrowsAsync<InventoryException>(() => M.UpdateInventoryCommandAsync(tunnel.Id, new InventoryCommand { Executable = "relative.exe" }));
        await M.UpdateExcludedRoutesAsync(tunnel.Id, ["10.0.5.0/24"]);
        await Assert.ThrowsAsync<InventoryException>(() => M.UpdateInventoryCommandAsync(tunnel.Id, Command));
        await M.UpdateExcludedRoutesAsync(tunnel.Id, []);
        await M.ConnectAsync(tunnel.Id);
        await Assert.ThrowsAsync<InventoryException>(() => M.UpdateInventoryCommandAsync(tunnel.Id, Command));
        Assert.Empty(S.Inventory);
    }

    [Fact]
    public async Task ConnectProtectsFirstThenAppliesTheCacheAndAFreshList()
    {
        var tunnel = await Ready();
        await M.UpdateInventoryCommandAsync(tunnel.Id, Command);
        S.Calls.Clear();
        await M.ConnectAsync(tunnel.Id);

        Assert.Equal(["inventory protect", $"start {tunnel.InterfaceName}", "inventory apply cached", "inventory apply"], InventoryCalls());
        Assert.Equal(["203.0.113.7/32"], S.Inventory[^1].DiscoveredPrefixes);
        // All requests of this connection share one generation; the service rejects older ones.
        Assert.Single(S.Inventory.Skip(1).Select(r => r.Generation).Distinct());
        Assert.Equal(["203.0.113.7/32"], tunnel.InventoryAllowedIPs);
        Assert.Equal(["192.0.2.0/24", "203.0.113.7/32"], tunnel.AllowedIPs);
        Assert.NotNull(tunnel.InventoryUpdatedAt);

        S.Calls.Clear();
        await M.DisconnectAsync(tunnel.Id);
        var calls = InventoryCalls();
        Assert.Equal("inventory protect", calls[0]); // blocked again before the adapter goes
        Assert.StartsWith("stop", calls[1]);
    }

    [Fact]
    public async Task AFailedRefreshKeepsTheLastGoodInventoryAndReportsIt()
    {
        var tunnel = await Ready();
        await M.UpdateInventoryCommandAsync(tunnel.Id, Command);
        await M.ConnectAsync(tunnel.Id);
        _h.Inventory.Fail = InventoryException.CommandFailed();
        await M.RefreshInventoryAsync(tunnel.Id);
        Assert.Equal(["203.0.113.7/32"], tunnel.InventoryAllowedIPs);
        Assert.Equal(InventoryException.CommandFailed().Message, M.InventoryErrorOf(tunnel.Id));
        Assert.True(tunnel.IsActive);
    }

    [Fact]
    public async Task ProtectedTunnelsCannotBeDeletedOrEditedUntilTheCommandIsRemoved()
    {
        var tunnel = await Ready();
        await M.UpdateInventoryCommandAsync(tunnel.Id, Command);
        M.Delete(tunnel.Id);
        Assert.Single(M.Tunnels);
        Assert.Throws<InvalidOperationException>(() => M.Update(tunnel.Id, "office", Harness.Config()));

        await M.UpdateInventoryCommandAsync(tunnel.Id, null);
        Assert.Equal(InventoryAction.Remove, S.Inventory[^1].Action);
        Assert.Null(tunnel.InventoryCommand);
        M.Delete(tunnel.Id);
        Assert.Empty(M.Tunnels);
    }

    [Fact]
    public async Task StartupProtectsAgainAndReopensRunningTunnels()
    {
        var tunnel = await Ready();
        await M.UpdateInventoryCommandAsync(tunnel.Id, Command);
        await M.ConnectAsync(tunnel.Id);
        S.Calls.Clear();
        _h.NewManager();
        await M.InitializeAsync();
        Assert.Equal(["inventory protect", "inventory apply cached", "inventory apply"], InventoryCalls());
    }

    [Fact]
    public async Task ResetRemovesProtectionAndEveryLocalFile()
    {
        var tunnel = await Ready();
        await M.UpdateInventoryCommandAsync(tunnel.Id, Command);
        await M.ConnectAsync(tunnel.Id);
        Assert.True(await M.ResetUserDataAsync(_h.Paths));
        Assert.Contains(S.Calls, c => c.StartsWith("stop"));
        Assert.Equal(InventoryAction.Remove, S.Inventory[^1].Action);
        Assert.Empty(M.Tunnels);
        Assert.False(Directory.Exists(_h.Paths.Configs));
        Assert.False(File.Exists(_h.Paths.TunnelsFile));
        Assert.Empty(S.Running);
    }
}

public class InventoryCommandRunnerTests
{
    private static InventoryCommand Cmd(params string[] script) => new() { Executable = Path.Combine(Environment.SystemDirectory, "cmd.exe"), Arguments = ["/d", "/c", .. script] };

    [Fact]
    public async Task CapturesTheCommandsOutputWithoutAShell()
    {
        if (!OperatingSystem.IsWindows()) return;
        var result = await new InventoryCommandRunner().RunAsync(Cmd("echo 192.0.2.1, 2001:db8::1"), default);
        Assert.Equal(["192.0.2.1/32", "2001:db8::1/128"], result);
    }

    [Fact]
    public async Task FailuresTimeoutsAndBadOutputAreReported()
    {
        if (!OperatingSystem.IsWindows()) return;
        var runner = new InventoryCommandRunner(TimeSpan.FromSeconds(2));
        Assert.Equal(InventoryException.CommandFailed().Message, (await Assert.ThrowsAsync<InventoryException>(() => runner.RunAsync(Cmd("exit 3"), default))).Message);
        Assert.Equal(IPPrefix(), (await Assert.ThrowsAsync<InventoryException>(() => runner.RunAsync(Cmd("echo not-an-ip"), default))).Message);
        var watch = Stopwatch.StartNew();
        Assert.Equal(InventoryException.TimedOut().Message, (await Assert.ThrowsAsync<InventoryException>(() => runner.RunAsync(Cmd("ping -n 30 127.0.0.1 >nul"), default))).Message);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10));
        Assert.Equal(InventoryException.InvalidCommand().Message,
            (await Assert.ThrowsAsync<InventoryException>(() => runner.RunAsync(new InventoryCommand { Executable = "cmd.exe" }, default))).Message);
    }

    private static string IPPrefix() => Core.Net.IPPrefix.InventoryOutputMessage;
}

public class QrCodeTests
{
    [Fact]
    public void DecodesAWireGuardConfigFromPixels()
    {
        var config = Harness.Config();
        var matrix = new MultiFormatWriter().encode(config, BarcodeFormat.QR_CODE, 400, 400);
        var pixels = new byte[matrix.Width * matrix.Height * 4];
        for (var y = 0; y < matrix.Height; y++)
            for (var x = 0; x < matrix.Width; x++)
            {
                var value = matrix[x, y] ? (byte)0 : (byte)255;
                var i = (y * matrix.Width + x) * 4;
                (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (value, value, value, 255);
            }
        Assert.Equal(config, QrCode.Decode(pixels, matrix.Width, matrix.Height));
        Assert.Null(QrCode.Decode(Enumerable.Repeat((byte)255, 64 * 64 * 4).ToArray(), 64, 64));
    }
}
