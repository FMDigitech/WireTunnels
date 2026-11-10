using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.AppLifecycle;
using WireTunnels.App.Services;
using WireTunnels.App.ViewModels;
using WireTunnels.App.Views;
using WireTunnels.Client;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Storage;

namespace WireTunnels.App;

public enum DashboardPage { Tunnels, Warnings, Log, Settings }

/// Composition root and lifetime: the app lives in the notification area; closing the dashboard
/// hides it, and only Quit (after every tunnel is disconnected) ends the process.
public partial class App : Application
{
    private static readonly TimeSpan DashboardPoll = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan BackgroundPoll = TimeSpan.FromSeconds(10);

    private readonly bool _startInBackground;
    private readonly AppLink? _pendingLink;
    private readonly string? _pendingImport;
    private SystemNetworkMonitor? _monitor;
    private Windows.UI.ViewManagement.UISettings? _uiSettings;
    private readonly DispatcherQueue _dispatcher;
    private readonly AppPaths _paths = AppPaths.ForCurrentUser();
    private readonly PipeTunnelService _service = new();
    private ToastNotifier? _notifier;
    private TrayIcon? _tray;
    private FlyoutWindow? _flyout;
    private MainWindow? _dashboard;
    private bool _quitting;

    /// A `.conf` path on the command line (double-click through the MSI's file association).
    public static bool IsConfigPath(string argument) =>
        argument.EndsWith(".conf", StringComparison.OrdinalIgnoreCase) && File.Exists(argument);

    /// Arguments of a redirected activation arrive as one string: split on spaces outside quotes.
    private static IEnumerable<string> Tokens(string? arguments) =>
        System.Text.RegularExpressions.Regex.Matches(arguments ?? "", @"""[^""]*""|\S+").Select(m => m.Value.Trim('"'));

    public App(AppInstance instance, bool startInBackground, AppLink? link, string? importPath)
    {
        _startInBackground = startInBackground;
        _pendingLink = link;
        _pendingImport = importPath;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        InitializeComponent();
        // A second launch: a wiretunnels:// link acts without opening the dashboard (except "show").
        instance.Activated += (_, e) =>
        {
            var arguments = e.Kind == ExtendedActivationKind.Launch && e.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch ? launch.Arguments : null;
            var tokens = Tokens(arguments).ToList();
            var forwarded = tokens.Select(AppLink.Parse).FirstOrDefault(l => l is not null);
            var conf = tokens.FirstOrDefault(IsConfigPath);
            _dispatcher.TryEnqueue(() =>
            {
                if (conf is not null) ImportFile(conf);
                if (forwarded is null) ShowDashboard(); else _ = HandleLinkAsync(forwarded);
            });
        };
        UnhandledException += (_, e) =>
        {
            Log?.Error($"Unexpected error: {e.Exception}");
            e.Handled = true; // keep the tray alive; the error is logged and shown
            if (Manager is not null) Manager.ErrorMessage = e.Message;
        };
    }

    public LogService Log { get; private set; } = null!;
    public TunnelManager Manager { get; private set; } = null!;
    public ShellViewModel Shell { get; private set; } = null!;
    public AppSettingsStore SettingsStore { get; private set; } = null!;
    public AppSettings Settings { get; private set; } = new();
    public UpdateService Updater { get; } = new(new HttpClient(), UpdateService.DefaultFeed, UpdateService.DefaultPublicKey,
        UpdateService.DefaultPublisher, WinTrust.Verify);
    public static Version CurrentVersion => typeof(App).Assembly.GetName().Version ?? new Version(0, 0);

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Log = new LogService(_paths.LogFile);
        Log.Info($"WireTunnels {typeof(App).Assembly.GetName().Version} starting");
        if (Environment.GetEnvironmentVariable("WIRETUNNELS_TRACE_EXCEPTIONS") == "1") // diagnostics only
            AppDomain.CurrentDomain.FirstChanceException += (_, e) => Log.Warning($"first chance: {e.Exception.GetType().Name}: {e.Exception.Message}\n{e.Exception.StackTrace}");
        // The macOS colours, light or dark like Windows, and again whenever the user switches.
        _uiSettings = new Windows.UI.ViewManagement.UISettings();
        MacPalette.Apply(MacPalette.SystemIsDark(_uiSettings));
        _uiSettings.ColorValuesChanged += (_, _) => _dispatcher.TryEnqueue(() => MacPalette.Apply(MacPalette.SystemIsDark(_uiSettings)));
        SettingsStore = new AppSettingsStore(_paths.SettingsFile);
        Settings = SettingsStore.Load();
        _notifier = new ToastNotifier(Log);
        _notifier.Invoked += () => _dispatcher.TryEnqueue(() => ShowDashboard());
        _notifier.Register();

        Manager = new TunnelManager(
            _service,
            new WindowsServiceProbe(),
            new ConfigStore(_paths.Configs, new DpapiConfigProtector()),
            new RecoverableJsonStore<List<Tunnel>>(_paths.TunnelsFile, () => []),
            Log,
            _notifier,
            () => Settings.ShowNotifications,
            hopChains: new RecoverableJsonStore<List<HopChain>>(_paths.HopChainsFile, () => []),
            canAdminister: () => Elevation.CanAdminister);
        Shell = new ShellViewModel(Manager);
        _flyout = new FlyoutWindow(this, Shell);
        _tray = new TrayIcon(Shell,
            toggleFlyout: () => _flyout.Toggle(),
            openDashboard: () => ShowDashboard(),
            connectFavorites: Manager.StartAllFavoritesAsync,
            disconnectAll: Manager.StopAllActiveAsync,
            quit: () => _ = QuitAsync());

        UrlProtocol.Register(Log);
        if (!_startInBackground && !Settings.StartInBackground) ShowDashboard();
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        await Manager.InitializeAsync();
        Manager.StartPolling(_dashboard?.IsVisible == true ? DashboardPoll : BackgroundPoll);
        _monitor = new SystemNetworkMonitor();
        await Manager.StartAutomationAsync(_monitor);
        if (_pendingLink is { } link) await HandleLinkAsync(link);
        if (_pendingImport is { } conf) ImportFile(conf);
        ReportUpdateResult();
        if (Settings.CheckForUpdates) await NotifyIfUpdateAsync();
    }

    private async Task NotifyIfUpdateAsync()
    {
        try
        {
            if (await Updater.CheckAsync(CurrentVersion) is { } update)
                _notifier?.Post("Update Available", $"WireTunnels {update.Version.ToString(3)} is available. Install it from Settings.");
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException) // offline: try again at the next start
        {
            Log.Info($"Update check skipped: {e.Message}");
        }
    }

    /// Settings > Install Update: download, verify (Ed25519 + Authenticode), disconnect like the Quit command,
    /// hand over to an elevated msiexec (UAC) that restarts the app afterwards, then exit. Throws with a user-readable message.
    public async Task InstallUpdateAsync(UpdateItem update)
    {
        var path = await Updater.DownloadAsync(update, Path.Combine(Path.GetTempPath(), "WireTunnels-update"));
        Log.Info($"Installing update {update.Version} from {path}");
        // Tunnels are disconnected first (Retry / Cancel as for Quit); Cancel leaves everything as it was.
        var command = UpdateHandoff.CommandLine(path, _paths.UpdateResultFile, Environment.ProcessPath!);
        Directory.CreateDirectory(_paths.Root);
        await QuitAsync(() =>
        {
            try { Process.Start(new ProcessStartInfo("cmd.exe", command) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Minimized }); }
            catch (System.ComponentModel.Win32Exception e) // UAC declined
            {
                throw new InvalidOperationException($"The installer was not started: {e.Message}", e);
            }
        });
    }

    /// First start after an update: say whether it installed (a failed MSI is rolled back by Windows Installer, so the
    /// previous version is what just started).
    private void ReportUpdateResult()
    {
        if (UpdateHandoff.Consume(_paths.UpdateResultFile) is not { } installed) return;
        Log.Info(installed ? $"Updated to {CurrentVersion}" : "The update did not install; the previous version was restored");
        _notifier?.Post(installed ? "WireTunnels Updated" : "Update Failed",
            installed ? $"WireTunnels {CurrentVersion.ToString(3)} is installed." : "The update could not be installed and the previous version was restored. Try again from Settings.");
    }

    /// Opening a `.conf` imports it (same path as drag and drop) and shows the dashboard.
    private void ImportFile(string path)
    {
        try { Manager.Import(path); }
        catch (Exception e) when (e is IOException or InvalidDataException or ConfigValidationException or UnauthorizedAccessException)
        {
            Manager.ErrorMessage = $"Import of {Path.GetFileName(path)} failed: {e.Message}";
        }
        ShowDashboard();
    }

    private async Task HandleLinkAsync(AppLink link)
    {
        if (link.Action == AppLinkAction.Show) ShowDashboard();
        else await Manager.HandleLinkAsync(link);
    }

    /// Settings > Reset App Data (macOS SettingsView.resetAppData): tunnels, inventory protection, configs,
    /// metadata and log through the manager, then this app's own preferences and Launch at Login.
    public async Task<bool> ResetAppDataAsync()
    {
        if (!await Manager.ResetUserDataAsync(_paths)) return false;
        try { LaunchAtLogin.Set(false); }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            Log.Warning($"Unable to turn off Launch at Login: {e.Message}");
        }
        Settings = new AppSettings();
        try { File.Delete(_paths.SettingsFile); }
        catch (IOException e) { Log.Warning($"Unable to delete the settings file: {e.Message}"); }
        Log.Info("App data was reset");
        return true;
    }

    public void SaveSettings()
    {
        try { SettingsStore.Save(Settings); }
        catch (IOException e) { Manager.ErrorMessage = $"Unable to save settings: {e.Message}"; }
    }

    public void ShowDashboard(Guid? tunnel = null, DashboardPage? page = null)
    {
        if (_quitting) return;
        _dashboard ??= CreateDashboard();
        _dashboard.Navigate(page, tunnel);
        _dashboard.Present();
    }

    private MainWindow CreateDashboard()
    {
        var window = new MainWindow(this, Shell);
        window.VisibilityChanged += (_, e) =>
        {
            if (!_quitting) Manager.StartPolling(e.Visible ? DashboardPoll : BackgroundPoll);
        };
        return window;
    }

    /// Port of prepareForQuit: disconnect everything first; on failure offer Retry / Cancel.
    /// `beforeExit` runs once every tunnel is disconnected; if it throws, the quit is cancelled and the app keeps running.
    public async Task QuitAsync(Action? beforeExit = null)
    {
        if (_quitting) return;
        _flyout?.HideFlyout();
        while (true)
        {
            if (await Manager.PrepareForQuitAsync()) break;
            ShowDashboard();
            var dialog = new ContentDialog
            {
                Title = "Unable to Quit",
                Content = string.Join("\n\n", new[] { Manager.QuitFailureReason, Manager.ErrorMessage }.Where(s => !string.IsNullOrEmpty(s)).Distinct()),
                PrimaryButtonText = "Retry",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = _dashboard!.Content.XamlRoot,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                await Manager.CancelQuitAsync();
                return;
            }
        }
        try { beforeExit?.Invoke(); }
        catch
        {
            await Manager.CancelQuitAsync();
            throw;
        }
        _quitting = true;
        Log.Info("Quit: exiting");
        _tray?.Dispose();
        _monitor?.Dispose();
        _notifier?.Dispose();
        await _service.DisposeAsync();
        Exit(); // the windows only hide on Close; Exit ends the process
    }
}
