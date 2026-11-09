using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using WireTunnels.App.Services;
using WireTunnels.App.ViewModels;
using WireTunnels.Client;

namespace WireTunnels.App.Views;

/// The dashboard (macOS MainDashboardView): sidebar sections, tunnel list + detail, warnings,
/// log and settings, with the setup wizard on top until the service is ready.
public sealed partial class MainWindow : Window
{
    private readonly App _app;

    public MainWindow(App app, ShellViewModel viewModel)
    {
        _app = app;
        ViewModel = viewModel;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        this.SetIcon();
        var logo = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "app-256.png")));
        TitleIcon.Source = logo;
        SetupIcon.Source = logo;
        this.CenterOnScreen(1120, 740);
        this.AppWindowOf().Closing += (_, e) =>
        {
            e.Cancel = true; // closing the dashboard keeps WireTunnels in the notification area
            this.AppWindowOf().Hide();
        };

        // The built-in item follows the Windows display language; the rest of the app is English.
        Nav.Loaded += (_, _) =>
        {
            if (Nav.SettingsItem is not NavigationViewItem settings) return;
            settings.Content = "Settings";
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(settings, "Settings");
        };
        Detail.Initialize(app, viewModel, OnDuplicated);
        LogPage.Initialize(app.Log);
        MultiHopPage.Initialize(viewModel.Manager);
        SettingsPage.Initialize(app);
        ViewModel.Manager.PropertyChanged += OnManagerChanged;
        UpdateSetup();
    }

    public ShellViewModel ViewModel { get; }
    public bool IsVisible => this.AppWindowOf().IsVisible;
    private TunnelManager Manager => ViewModel.Manager;

    public void Navigate(DashboardPage? page, Guid? tunnel)
    {
        if (tunnel is { } id)
        {
            Select("All");
            if (ViewModel.ItemFor(id) is { } item) TunnelList.SelectedItem = item;
            return;
        }
        switch (page)
        {
            case DashboardPage.Settings: Nav.SelectedItem = Nav.SettingsItem; break;
            case DashboardPage.Log: Select("Log"); break;
            case DashboardPage.Warnings: Select("Warnings"); break;
            case DashboardPage.Tunnels: Select("All"); break;
        }
    }

    private void Select(string tag) =>
        Nav.SelectedItem = Nav.MenuItems.Concat(Nav.FooterMenuItems).OfType<NavigationViewItem>().First(i => (string)i.Tag == tag);

    private void OnNavigationChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        UIElement page;
        if (args.IsSettingsSelected) page = SettingsPage;
        else
        {
            var tag = (args.SelectedItem as NavigationViewItem)?.Tag as string;
            page = tag switch
            {
                "Warnings" => WarningsPage,
                "MultiHop" => MultiHopPage,
                "Log" => LogPage,
                _ => TunnelsPage,
            };
            if (page == TunnelsPage)
            {
                ViewModel.Section = tag switch
                {
                    "Active" => TunnelSection.Active,
                    "Shared" => TunnelSection.Shared,
                    "Favorites" => TunnelSection.Favorites,
                    _ => TunnelSection.All,
                };
                TunnelList.SelectedItem = null;
            }
        }
        foreach (var p in new UIElement[] { TunnelsPage, WarningsPage, MultiHopPage, LogPage, SettingsPage })
            p.Visibility = p == page ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnTunnelSelected(object sender, SelectionChangedEventArgs e)
    {
        var item = TunnelList.SelectedItem as TunnelItem;
        Detail.Item = item;
        Detail.Visibility = item is null ? Visibility.Collapsed : Visibility.Visible;
        NoSelection.Visibility = item is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnDuplicated(Guid id)
    {
        if (ViewModel.ItemFor(id) is { } item) TunnelList.SelectedItem = item;
    }

    private static TunnelItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as TunnelItem;

    private async void OnToggled(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleSwitch toggle || ItemOf(sender) is not { } item || toggle.IsOn == item.IsActive) return;
        if (toggle.IsOn) await Manager.ConnectAsync(item.Id);
        else await Manager.DisconnectAsync(item.Id);
        toggle.IsOn = item.IsActive;
    }

    private void OnFavorite(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) Manager.ToggleFavorite(item.Id);
    }

    private void OnDuplicate(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } item) return;
        try { OnDuplicated(Manager.Duplicate(item.Id).Id); }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or InvalidDataException or ConfigValidationException)
        {
            Manager.ErrorMessage = ex.Message;
        }
    }

    private async void OnImport(object sender, RoutedEventArgs e)
    {
        if (await new ImportDialog(_app, Content.XamlRoot, this).ShowImportAsync() is { } id) OnDuplicated(id);
    }

    private async void OnNewTunnel(object sender, RoutedEventArgs e)
    {
        if (await TunnelEditorDialog.CreateAsync(_app, Content.XamlRoot) is { } id) OnDuplicated(id);
    }

    private void OnErrorClosed(InfoBar sender, object args) => Manager.ErrorMessage = null;

    // MARK: drag & drop of .conf files anywhere on the dashboard

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Import tunnel";
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var files = (await e.DataView.GetStorageItemsAsync()).OfType<StorageFile>().ToList();
        Guid? last = null;
        foreach (var file in files)
        {
            if (!file.Path.EndsWith(".conf", StringComparison.OrdinalIgnoreCase))
            {
                Manager.ErrorMessage = $"{file.Name}: only .conf files can be imported.";
                continue;
            }
            try { last = Manager.Import(file.Path).Id; }
            catch (Exception ex) when (ex is IOException or InvalidDataException or ConfigValidationException or UnauthorizedAccessException)
            {
                Manager.ErrorMessage = $"Import of {file.Name} failed: {ex.Message}";
            }
        }
        if (last is { } id) OnDuplicated(id);
    }

    // MARK: setup wizard (macOS SetupWizardView)

    private void OnManagerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TunnelManager.SetupState) or nameof(TunnelManager.IsInitialized) or nameof(TunnelManager.SetupDetail))
            UpdateSetup();
    }

    private void UpdateSetup()
    {
        var m = Manager;
        var show = !m.IsInitialized || m.NeedsSetup;
        SetupOverlay.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (!show) return;
        var loading = !m.IsInitialized || m.SetupState == SetupState.Checking;
        SetupLoading.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        SetupSteps.Visibility = loading ? Visibility.Collapsed : Visibility.Visible;
        (SetupTitle.Text, SetupMessage.Text, var canStart) = m.SetupState switch
        {
            SetupState.ServiceMissing => ("Install the WireTunnels Service",
                "The WireTunnels service is not installed on this PC. Run the WireTunnels installer. "
                + "Developer builds: install the service as described in windows\\README.md.", false),
            SetupState.ServiceStopped => ("Start the WireTunnels Service",
                "The service is installed but stopped. Starting it requires administrator approval.", true),
            SetupState.ServiceStarting => ("The Service Is Starting", "Waiting for the WireTunnels service to finish starting…", false),
            SetupState.Incompatible => ("Update WireTunnels", m.SetupDetail ?? "The service belongs to another version of WireTunnels.", false),
            _ => ("The Service Does Not Respond", m.SetupDetail ?? "The WireTunnels service is running but does not answer.", false),
        };
        SetupStart.Visibility = canStart ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnStartService(object sender, RoutedEventArgs e)
    {
        SetupBusy.IsActive = true;
        try
        {
            if (!await ServiceControl.StartElevatedAsync()) return;
            for (var i = 0; i < 20 && Manager.NeedsSetup; i++)
            {
                await Task.Delay(500);
                await Manager.RefreshServiceStateAsync();
            }
            if (!Manager.NeedsSetup) await Manager.RefreshStatusAsync(reportError: false);
        }
        finally { SetupBusy.IsActive = false; }
    }

    private async void OnCheckService(object sender, RoutedEventArgs e)
    {
        SetupBusy.IsActive = true;
        try
        {
            await Manager.RefreshServiceStateAsync();
            if (!Manager.NeedsSetup) await Manager.RefreshStatusAsync(reportError: false);
        }
        finally { SetupBusy.IsActive = false; }
    }
}
