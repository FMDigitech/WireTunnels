using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.UIA3;
using Application = FlaUI.Core.Application;
using WireTunnels.Client;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Storage;

namespace WireTunnels.App.UITests;

/// UI smoke tests that drive the real app with UI Automation (FlaUI). They run the installed app (the
/// service only answers apps in its own folder) against a throw-away data folder, so the user's own
/// tunnels are never touched. Opt-in: WIRETUNNELS_UI_TESTS=1, and optionally WIRETUNNELS_APP=<exe>.
public sealed class DashboardTests : IDisposable
{
    private static bool Enabled => System.OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("WIRETUNNELS_UI_TESTS") == "1";
    private static string AppExe => Environment.GetEnvironmentVariable("WIRETUNNELS_APP") is { Length: > 0 } exe
        ? exe : @"C:\Program Files\WireTunnels\WireTunnels.App.exe";
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(15);

    private readonly string _data = Path.Combine(Path.GetTempPath(), "wt-ui-" + Guid.NewGuid().ToString("N"));
    private readonly AppPaths _paths;
    private Application? _app;
    private UIA3Automation? _automation;
    private Window _window = null!;

    public DashboardTests() => _paths = new AppPaths(_data);

    public void Dispose()
    {
        try { _app?.Kill(); } catch (InvalidOperationException) { }
        _app?.Dispose();
        _automation?.Dispose();
        try { Directory.Delete(_data, recursive: true); } catch (IOException) { }
    }

    private static string Config(string address) => $"""
        [Interface]
        PrivateKey = {WireGuardKey.Generate().PrivateKey}
        Address = {address}
        DNS = 10.99.0.1
        [Peer]
        PublicKey = {WireGuardKey.Generate().PublicKey}
        Endpoint = 192.0.2.10:51820
        AllowedIPs = 10.99.0.0/24
        """;

    /// Seeds tunnels with the same libraries the app uses, then starts the app on that data folder.
    private void Launch(params string[] tunnels)
    {
        var manager = new TunnelManager(new PipeTunnelService(), new WindowsServiceProbe(), new ConfigStore(_paths.Configs, new DpapiConfigProtector()),
            new RecoverableJsonStore<List<Tunnel>>(_paths.TunnelsFile, () => []), new LogService(_paths.LogFile), new NullNotifier(), () => false);
        for (var i = 0; i < tunnels.Length; i++) manager.Create(tunnels[i], Config($"10.99.0.{i + 2}/32"));

        var info = new ProcessStartInfo(AppExe) { UseShellExecute = false };
        info.Environment[AppPaths.DataDirectoryVariable] = _data;
        _app = Application.Launch(info);
        _automation = new UIA3Automation();
        _window = Retry.WhileNull(() => _app.GetAllTopLevelWindows(_automation).FirstOrDefault(w => w.Name.Contains("WireTunnels") && !w.IsOffscreen),
            Timeout, throwOnTimeout: true).Result!;
        // The setup wizard covers everything until the service answers.
        Find("All Tunnels");
        Assert.Null(Retry.WhileNull(() => _window.FindFirstDescendant(c => c.ByName("The Service Does Not Respond")), TimeSpan.FromSeconds(2)).Result);
    }

    private AutomationElement Find(string name, ControlType? type = null) =>
        // A rebuilt page can briefly hand out stale elements (E_UNEXPECTED): retry through them.
        Retry.WhileNull(() => _window.FindFirstDescendant(c => type is { } t ? c.ByName(name).And(c.ByControlType(t)) : c.ByName(name)), Timeout, ignoreException: true).Result
        ?? throw new Xunit.Sdk.XunitException($"UI element not found: {name}");

    private void Select(string name) => Find(name).Patterns.SelectionItem.Pattern.Select();

    /// Escape, not "Close": the title bar's Close button has that name too, and it hides the dashboard.
    private void CloseDialog()
    {
        _window.Focus();
        FlaUI.Core.Input.Keyboard.Press(FlaUI.Core.WindowsAPI.VirtualKeyShort.ESCAPE);
        Thread.Sleep(500);
    }

    [Fact]
    public void TheDetailPaneShowsTheNetworkSectionsAndSavesAnExclusion()
    {
        if (!Enabled) return;
        Launch("ui-one");
        Select("ui-one, Disconnected");
        foreach (var section in new[] { "Kill Switch", "Split Tunnel Exclusions", "Split DNS", "Inventory AllowedIPs" }) Find(section);

        Find("Add excluded range", ControlType.Edit).AsTextBox().Text = "10.0.5.0/24";
        Find("Add excluded range", ControlType.Button).AsButton().Invoke();
        Find("Remove 10.0.5.0/24");
        Assert.True(Retry.WhileFalse(() => File.ReadAllText(_paths.TunnelsFile).Contains("10.0.5.0/24"), Timeout).Result);
    }

    [Fact]
    public void AMultiHopChainCanBeAddedAndRemoved()
    {
        if (!Enabled) return;
        Launch("ui-hop", "ui-exit");
        Select("Multi-Hop");
        Find("No chains yet. Pick a hop and an exit tunnel below.");
        Find("Hop", ControlType.ComboBox).AsComboBox().Select("ui-hop");
        Find("Exit", ControlType.ComboBox).AsComboBox().Select("ui-exit");
        Find("Add Chain", ControlType.Button).AsButton().Invoke();
        Find("Remove chain", ControlType.Button);
        Assert.True(Retry.WhileFalse(() => File.Exists(_paths.HopChainsFile) && File.ReadAllText(_paths.HopChainsFile).Contains("hopTunnelID"), Timeout).Result);

        Find("Remove chain", ControlType.Button).AsButton().Invoke();
        Find("No chains yet. Pick a hop and an exit tunnel below.");
    }

    [Fact]
    public void TheImportDialogOffersQrCodes()
    {
        if (!Enabled) return;
        Launch();
        Find("Import Config", ControlType.Button).AsButton().Invoke();
        Find("Paste QR Code from Clipboard", ControlType.Button);
        Find("Drop a .conf file or a QR code image here");
        CloseDialog();
    }

    [Fact]
    public void AQrCodeOnTheClipboardIsImported()
    {
        if (!Enabled) return;
        var config = Config("10.99.0.2/32");
        var matrix = new ZXing.MultiFormatWriter().encode(config, ZXing.BarcodeFormat.QR_CODE, 600, 600);
        using var bitmap = new System.Drawing.Bitmap(matrix.Width, matrix.Height);
        for (var y = 0; y < matrix.Height; y++)
            for (var x = 0; x < matrix.Width; x++)
                bitmap.SetPixel(x, y, matrix[x, y] ? System.Drawing.Color.Black : System.Drawing.Color.White);
        var clipboard = new Thread(() => System.Windows.Forms.Clipboard.SetImage(bitmap));
        clipboard.SetApartmentState(ApartmentState.STA);
        clipboard.Start();
        clipboard.Join();

        Launch();
        Find("Import Config", ControlType.Button).AsButton().Invoke();
        Find("Paste QR Code from Clipboard", ControlType.Button).AsButton().Invoke();
        Find("Tunnel \"QR Import\" has been added.");
        CloseDialog();
        var row = Retry.WhileNull(() => _window.FindAllDescendants(c => c.ByControlType(ControlType.ListItem)).FirstOrDefault(e => e.Name.StartsWith("QR Import")),
            Timeout, ignoreException: true).Result;
        Assert.True(row is not null, "list items: " + string.Join(" | ", _window.FindAllDescendants(c => c.ByControlType(ControlType.ListItem)).Select(e => e.Name)));
        Assert.Contains("\"QR Import\"", File.ReadAllText(_paths.TunnelsFile));
    }

    [Fact]
    public void ResetAppDataRemovesTheTunnels()
    {
        if (!Enabled) return;
        Launch("ui-reset");
        _window.FindFirstDescendant(c => c.ByName("Settings").And(c.ByControlType(ControlType.ListItem)))?.Patterns.SelectionItem.Pattern.Select();
        Find("Reset App Data", ControlType.Button).AsButton().Invoke();
        Find("Reset", ControlType.Button).AsButton().Invoke();
        Assert.True(Retry.WhileFalse(() => !Directory.Exists(_paths.Configs) && !File.Exists(_paths.TunnelsFile), Timeout).Result);
        Assert.False(_app!.HasExited);
        Select("All Tunnels");
        Find("No Tunnels");
    }
}
