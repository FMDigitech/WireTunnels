using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using WireTunnels.App.Services;
using WireTunnels.Client;

namespace WireTunnels.App.Views;

/// Application Log (macOS LogView): live entries, copy, clear and the log folder.
public sealed class LogView : UserControl
{
    private readonly ObservableCollection<string> _lines = [];
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Extended, IsItemClickEnabled = false };
    private readonly TextBlock _empty = new() { Text = "No log entries. Activity will appear here as you use the app.", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private LogService _log = null!;
    private DispatcherQueue _dispatcher = null!;

    public void Initialize(LogService log)
    {
        _log = log;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        foreach (var line in log.Entries) _lines.Add(line);
        log.EntryAdded += line => _dispatcher.TryEnqueue(() => Append(line));
        log.Cleared += () => _dispatcher.TryEnqueue(() => { _lines.Clear(); UpdateEmpty(); });

        _list.ItemsSource = _lines;
        _list.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(
            """
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                <TextBlock Text="{Binding}" FontFamily="Cascadia Mono, Consolas" FontSize="12" TextWrapping="Wrap" IsTextSelectionEnabled="True" />
            </DataTemplate>
            """);
        AutomationProperties.SetName(_list, "Log entries");

        var copy = Command("Copy", "", () =>
        {
            var selected = _list.SelectedItems.Cast<string>().ToList();
            var package = new DataPackage();
            package.SetText(string.Join(Environment.NewLine, selected.Count > 0 ? selected : _lines));
            Clipboard.SetContent(package);
        });
        var folder = Command("Open Folder", "", () => Process.Start(new ProcessStartInfo(Path.GetDirectoryName(_log.FilePath)!) { UseShellExecute = true }));
        var clear = Command("Clear", "", () => _log.Clear());

        var header = new Grid { Padding = new Thickness(24, 16, 24, 8) };
        header.Children.Add(new TextBlock { Text = "Application Log", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(copy);
        buttons.Children.Add(folder);
        buttons.Children.Add(clear);
        header.Children.Add(buttons);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(header);
        var body = new Grid { Margin = new Thickness(16, 0, 16, 16) };
        body.Children.Add(_list);
        body.Children.Add(_empty);
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        Content = root;
        UpdateEmpty();
        Loaded += (_, _) => ScrollToEnd();
    }

    private static Button Command(string text, string glyph, Action action)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        content.Children.Add(new TextBlock { Text = text });
        var button = new Button { Content = content };
        AutomationProperties.SetName(button, text); // icon + text content has no accessible name of its own
        button.Click += (_, _) => action();
        return button;
    }

    private void Append(string line)
    {
        _lines.Add(line);
        while (_lines.Count > LogService.MaxEntries) _lines.RemoveAt(0);
        UpdateEmpty();
        if (Visibility == Visibility.Visible) ScrollToEnd();
    }

    private void ScrollToEnd()
    {
        if (_lines.Count > 0) _list.ScrollIntoView(_lines[^1]);
    }

    private void UpdateEmpty() => _empty.Visibility = _lines.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
}

/// Settings (macOS SettingsView, the parts that apply on Windows today).
public sealed class SettingsView : UserControl
{
    private App _app = null!;
    private TextBlock _serviceState = new();

    public void Initialize(App app)
    {
        _app = app;
        _app.Manager.PropertyChanged += OnManagerChanged;
        Build();
    }

    /// Also after Reset App Data, so the toggles show the defaults again.
    private void Build()
    {
        // A fresh element each time: one still in the previous page cannot get a second parent.
        _serviceState = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var paths = AppPaths.ForCurrentUser();
        var panel = new StackPanel { Spacing = 16, Padding = new Thickness(24, 16, 24, 24), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
        panel.Children.Add(new TextBlock { Text = "Settings", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });

        var check = new Button { Content = "Check Again" };
        check.Click += async (_, _) => await _app.Manager.RefreshServiceStateAsync();
        panel.Children.Add(Section("WireTunnels Service", "",
            _serviceState,
            Caption("The service runs as LocalSystem and creates the WireGuard adapters (wireguard-nt). This app talks to it through a local pipe that only accepts your own requests."),
            check));

        var openConfigs = new Button { Content = "Open Folder" };
        openConfigs.Click += (_, _) =>
        {
            Directory.CreateDirectory(paths.Root);
            Process.Start(new ProcessStartInfo(paths.Root) { UseShellExecute = true });
        };
        panel.Children.Add(Section("Config Storage", "",
            new TextBlock { Text = paths.Root, FontFamily = (FontFamily)Application.Current.Resources["MonoFont"], IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap },
            Caption("Configurations are encrypted with your Windows account (DPAPI): other users of this PC cannot read your private keys."),
            openConfigs));

        StackPanel launch = null!;
        launch = Toggle("Launch at Login", "Start WireTunnels in the notification area when you sign in to Windows.", LaunchAtLogin.IsEnabled, async on =>
        {
            // An administrator may require approval to turn it off (system setting, macOS requireAdminToDisableLaunchAtLogin).
            if (!on && LaunchAtLogin.IsEnabled && !await _app.Manager.AuthorizeDisablingLaunchAtLoginAsync())
            {
                ((ToggleSwitch)launch.Children[0]).IsOn = true;
                _app.Manager.ErrorMessage = "Your administrator requires approval to turn off Launch at Login.";
                return;
            }
            try { LaunchAtLogin.Set(on); }
            catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException)
            {
                _app.Manager.ErrorMessage = $"Unable to change Launch at Login: {e.Message}";
            }
        });
        var background = Toggle("Start in Background", "Don't open the dashboard window when WireTunnels starts. Open it from the notification-area icon.",
            _app.Settings.StartInBackground, on => { _app.Settings.StartInBackground = on; _app.SaveSettings(); });
        var notifications = Toggle("Show Notifications", "Notify when tunnels connect, disconnect, or encounter errors.",
            _app.Settings.ShowNotifications, on => { _app.Settings.ShowNotifications = on; _app.SaveSettings(); });
        panel.Children.Add(Section("Behavior", "", launch, background, notifications));

        if (_app.Manager.CanAdminister)
        {
            StackPanel require = null!;
            require = Toggle("Require an Administrator to Turn Off Launch at Login",
                "Applies to every user of this PC. Changing it asks for administrator approval.",
                _app.Manager.SystemSettings.RequireAdminToDisableLaunchAtLogin, async on =>
                {
                    if (on == _app.Manager.SystemSettings.RequireAdminToDisableLaunchAtLogin) return;
                    try { await _app.Manager.SetRequireAdminToDisableLaunchAtLoginAsync(on); }
                    catch (Exception e) when (e is Contracts.ServiceException or IOException or UnauthorizedAccessException)
                    {
                        _app.Manager.ErrorMessage = $"Unable to change the setting: {e.Message}";
                        ((ToggleSwitch)require.Children[0]).IsOn = !on;
                    }
                });
            panel.Children.Add(Section("Administrator", "", require,
                Caption("Shared tunnels are managed from their detail pane: Make Shared on a personal tunnel, then set who can connect and disconnect it.")));
        }

        var reset = new Button { Content = "Reset…" };
        AutomationProperties.SetName(reset, "Reset App Data");
        reset.Click += async (_, _) =>
        {
            var dialog = new ContentDialog
            {
                Title = "Reset All App Data?",
                Content = "All tunnels and preferences will be permanently deleted. Connected tunnels are disconnected first.",
                PrimaryButtonText = "Reset",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = XamlRoot,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            reset.IsEnabled = false;
            if (await _app.ResetAppDataAsync()) Build();
            else reset.IsEnabled = true;
        };
        var resetTitle = new TextBlock { Text = "Reset App Data", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["ErrorBrush"] };
        panel.Children.Add(Section("Advanced", "\uE7BA", resetTitle,
            Caption("Removes all tunnels, preferences, and cached data, including inventory protection. This cannot be undone."), reset));

        var version = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "";
        panel.Children.Add(Section("About", "",
            new TextBlock { Text = $"WireTunnels {version} for Windows", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] },
            Caption("Created by FMDigitech. WireGuard is a registered trademark of Jason A. Donenfeld.")));

        Content = new ScrollViewer { Content = panel };
        UpdateService();
    }

    private void OnManagerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TunnelManager.SetupState) or nameof(TunnelManager.ServiceVersion)) UpdateService();
    }

    private void UpdateService()
    {
        var m = _app.Manager;
        _serviceState.Text = m.SetupState == SetupState.Ready
            ? $"Running, version {m.ServiceVersion}"
            : m.ConnectionUnavailableReason ?? m.SetupState.ToString();
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };

    private static StackPanel Toggle(string header, string description, bool value, Action<bool> changed)
    {
        var toggle = new ToggleSwitch { Header = header, IsOn = value };
        toggle.Toggled += (_, _) => changed(toggle.IsOn);
        AutomationProperties.SetHelpText(toggle, description);
        var stack = new StackPanel { Spacing = 0 };
        stack.Children.Add(toggle);
        stack.Children.Add(Caption(description));
        return stack;
    }

    private static Border Section(string title, string glyph, params UIElement[] content)
    {
        var stack = new StackPanel { Spacing = 10 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(new FontIcon { Glyph = glyph, FontSize = 16 });
        head.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        stack.Children.Add(head);
        foreach (var element in content) stack.Children.Add(element);
        return new Border { Style = (Style)Application.Current.Resources["Card"], Child = stack };
    }
}
