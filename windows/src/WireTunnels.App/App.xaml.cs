using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.AppLifecycle;
using WireTunnels.App.Services;
using WireTunnels.App.ViewModels;
using WireTunnels.App.Views;
using WireTunnels.Client;
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
    private readonly DispatcherQueue _dispatcher;
    private readonly AppPaths _paths = AppPaths.ForCurrentUser();
    private readonly PipeTunnelService _service = new();
    private ToastNotifier? _notifier;
    private TrayIcon? _tray;
    private FlyoutWindow? _flyout;
    private MainWindow? _dashboard;
    private bool _quitting;

    public App(AppInstance instance, bool startInBackground)
    {
        _startInBackground = startInBackground;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        InitializeComponent();
        instance.Activated += (_, _) => _dispatcher.TryEnqueue(() => ShowDashboard());
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

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Log = new LogService(_paths.LogFile);
        Log.Info($"WireTunnels {typeof(App).Assembly.GetName().Version} starting");
        if (Environment.GetEnvironmentVariable("WIRETUNNELS_TRACE_EXCEPTIONS") == "1") // diagnostics only
            AppDomain.CurrentDomain.FirstChanceException += (_, e) => Log.Warning($"first chance: {e.Exception.GetType().Name}: {e.Exception.Message}\n{e.Exception.StackTrace}");
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
            hopChains: new RecoverableJsonStore<List<HopChain>>(_paths.HopChainsFile, () => []));
        Shell = new ShellViewModel(Manager);
        _flyout = new FlyoutWindow(this, Shell);
        _tray = new TrayIcon(Shell,
            toggleFlyout: () => _flyout.Toggle(),
            openDashboard: () => ShowDashboard(),
            connectFavorites: Manager.StartAllFavoritesAsync,
            disconnectAll: Manager.StopAllActiveAsync,
            quit: () => _ = QuitAsync());

        if (!_startInBackground && !Settings.StartInBackground) ShowDashboard();
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        await Manager.InitializeAsync();
        Manager.StartPolling(_dashboard?.IsVisible == true ? DashboardPoll : BackgroundPoll);
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
    public async Task QuitAsync()
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
        _quitting = true;
        Log.Info("Quit: exiting");
        _tray?.Dispose();
        _notifier?.Dispose();
        await _service.DisposeAsync();
        Exit(); // the windows only hide on Close; Exit ends the process
    }
}
