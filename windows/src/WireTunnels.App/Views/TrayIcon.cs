using System.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using H.NotifyIcon;
using Microsoft.UI.Xaml.Controls;
using WireTunnels.App.ViewModels;
using WireTunnels.Client;

namespace WireTunnels.App.Views;

/// The notification-area icon (macOS MenuBarExtra): its colour is the connection state, a left
/// click opens the flyout, a right click the context menu of section 8 of the architecture doc.
public sealed class TrayIcon : IDisposable
{
    private readonly ShellViewModel _vm;
    private readonly TaskbarIcon _icon;
    private readonly MenuFlyoutItem _favorites, _disconnectAll;
    private string _current = "";

    public TrayIcon(ShellViewModel vm, Action toggleFlyout, Action openDashboard, Func<Task> connectFavorites, Func<Task> disconnectAll, Action quit)
    {
        _vm = vm;
        _favorites = Item("Connect Favorites", "", () => _ = connectFavorites());
        _disconnectAll = Item("Disconnect All", "", () => _ = disconnectAll());
        var menu = new MenuFlyout();
        menu.Items.Add(Item("Open Dashboard", "", openDashboard));
        menu.Items.Add(_favorites);
        menu.Items.Add(_disconnectAll);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Quit WireTunnels", "", quit));

        _icon = new TaskbarIcon
        {
            ToolTipText = "WireTunnels",
            NoLeftClickDelay = true,
            ContextMenuMode = ContextMenuMode.PopupMenu,
            LeftClickCommand = new RelayCommand(toggleFlyout),
            DoubleClickCommand = new RelayCommand(openDashboard),
            ContextFlyout = menu,
        };
        Update();
        _icon.ForceCreate(enablesEfficiencyMode: false);
        vm.PropertyChanged += OnChanged;
        vm.Manager.PropertyChanged += OnChanged;
    }

    private static MenuFlyoutItem Item(string text, string glyph, Action action) =>
        new() { Text = text, Icon = new FontIcon { Glyph = glyph }, Command = new RelayCommand(action) };

    private void OnChanged(object? sender, PropertyChangedEventArgs e) => Update();

    private void Update()
    {
        var state = _vm.SetupNotice is not null ? "error"
            : _vm.TrayStatus switch
            {
                ConnectionStatus.Connecting or ConnectionStatus.Reconnecting => "connecting",
                ConnectionStatus.ConnectionLost => "error",
                _ when _vm.HasWarnings => "warning",
                ConnectionStatus.Connected => "connected",
                _ => "idle",
            };
        var tip = _vm.SetupNotice ?? (_vm.TrayStatus == ConnectionStatus.Connected
            ? $"Connected ({_vm.ActiveCount} tunnel{(_vm.ActiveCount == 1 ? "" : "s")})"
            : ConnectionStatusText.Describe(_vm.TrayStatus));
        if (_vm.HasWarnings && _vm.SetupNotice is null) tip += $" · {_vm.WarningCount} warning{(_vm.WarningCount == 1 ? "" : "s")}";
        _icon.ToolTipText = $"WireTunnels — {tip}";
        _favorites.IsEnabled = _vm.HasInactiveFavorites && _vm.Manager.CanConnectTunnels;
        _disconnectAll.IsEnabled = _vm.HasActive && !_vm.AnyBusy;
        if (state == _current) return;
        _current = state;
        // A new Icon every time: TaskbarIcon disposes the previous one when the property changes,
        // so a cached instance would be disposed the next time it is shown (and crash in native code).
        _icon.Icon = new System.Drawing.Icon(Path.Combine(AppContext.BaseDirectory, "Assets", $"{state}.ico"));
    }

    public void Dispose()
    {
        _vm.PropertyChanged -= OnChanged;
        _vm.Manager.PropertyChanged -= OnChanged;
        _icon.Dispose();
    }
}

/// x:Bind helpers. Functions bound to Visibility return Visibility: the XAML compiler generates
/// broken code for the implicit bool → Visibility cast of a function result (WMC, WinAppSDK 2.6).
public static class Bind
{
    public static bool IsSet(object? value) => value is not null && value is not "";
    public static bool Not(bool value) => !value;
    public static Microsoft.UI.Xaml.Visibility VisibleIfPositive(int value) =>
        value > 0 ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
    public static Microsoft.UI.Xaml.Visibility CollapsedIf(bool value) =>
        value ? Microsoft.UI.Xaml.Visibility.Collapsed : Microsoft.UI.Xaml.Visibility.Visible;
    public static string Text(string? value) => value ?? "";
}
