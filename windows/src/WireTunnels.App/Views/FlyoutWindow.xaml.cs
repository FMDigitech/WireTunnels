using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using WireTunnels.App.Services;
using WireTunnels.App.ViewModels;

namespace WireTunnels.App.Views;

/// The tray flyout (macOS MenuBarView): a borderless, always-on-top window anchored to the
/// notification area, hidden as soon as it loses focus.
public sealed partial class FlyoutWindow : Window
{
    private const int WidthDip = 340;
    private const int MarginDip = 12;
    private readonly App _app;
    private DateTime _hiddenAt;

    public FlyoutWindow(App app, ShellViewModel viewModel)
    {
        _app = app;
        ViewModel = viewModel;
        InitializeComponent();

        var appWindow = this.AppWindowOf();
        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        appWindow.SetPresenter(presenter);
        appWindow.IsShownInSwitchers = false;
        appWindow.Closing += (_, e) => { e.Cancel = true; HideFlyout(); };
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated) HideFlyout();
        };
        // Never resize inside a layout pass (re-entrant layout crashes XAML): queue one placement after it.
        Panel.SizeChanged += (_, _) =>
        {
            if (!appWindow.IsVisible || _placementQueued) return;
            _placementQueued = true;
            DispatcherQueue.TryEnqueue(() =>
            {
                _placementQueued = false;
                if (appWindow.IsVisible) Place();
            });
        };
    }

    private bool _placementQueued;

    public ShellViewModel ViewModel { get; }

    public bool IsOpen => this.AppWindowOf().IsVisible;

    /// The tray click that deactivated the flyout must not reopen it right away.
    public void Toggle()
    {
        if (IsOpen) HideFlyout();
        else if ((DateTime.UtcNow - _hiddenAt).TotalMilliseconds > 300) ShowFlyout();
    }

    public void ShowFlyout()
    {
        ViewModel.Refresh();
        Place();
        this.Present();
        Panel.Focus(FocusState.Programmatic);
    }

    public void HideFlyout()
    {
        if (!IsOpen) return;
        _hiddenAt = DateTime.UtcNow;
        this.AppWindowOf().Hide();
    }

    /// Bottom-right (or next to wherever the taskbar is) of the work area under the cursor.
    private void Place()
    {
        var scale = this.Scale();
        Panel.Measure(new Windows.Foundation.Size(WidthDip, double.PositiveInfinity));
        var width = (int)(WidthDip * scale);
        var height = (int)(Math.Min(Panel.DesiredSize.Height + 2, 680) * scale);
        GetCursorPos(out var cursor);
        var area = DisplayArea.GetFromPoint(new Windows.Graphics.PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Nearest).WorkArea;
        var margin = (int)(MarginDip * scale);
        height = Math.Min(height, area.Height - 2 * margin);
        var x = Math.Clamp(cursor.X - width / 2, area.X + margin, area.X + area.Width - width - margin);
        var y = cursor.Y > area.Y + area.Height / 2 ? area.Y + area.Height - height - margin : area.Y + margin;
        if (cursor.X > area.X + area.Width - width) x = area.X + area.Width - width - margin;
        this.AppWindowOf().MoveAndResize(new Windows.Graphics.RectInt32(x, y, width, height));
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape) HideFlyout();
    }

    private static TunnelItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as TunnelItem;

    private async void OnToggled(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleSwitch toggle || ItemOf(sender) is not { } item || toggle.IsOn == item.IsActive) return;
        if (toggle.IsOn) await ViewModel.Manager.ConnectAsync(item.Id);
        else await ViewModel.Manager.DisconnectAsync(item.Id);
        toggle.IsOn = item.IsActive; // a failed operation flips the switch back
    }

    private async void OnRetry(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) await ViewModel.Manager.ConnectAsync(item.Id);
    }

    private void OnDetails(object sender, RoutedEventArgs e)
    {
        HideFlyout();
        _app.ShowDashboard(ItemOf(sender)?.Id);
    }

    private void OnErrorClosed(InfoBar sender, object args) => ViewModel.Manager.ErrorMessage = null;
    private async void OnStartFavorites(object sender, RoutedEventArgs e) => await ViewModel.Manager.StartAllFavoritesAsync();
    private async void OnStopAll(object sender, RoutedEventArgs e) => await ViewModel.Manager.StopAllActiveAsync();

    private void OnOpenDashboard(object sender, RoutedEventArgs e)
    {
        HideFlyout();
        _app.ShowDashboard();
    }

    private void OnOpenSettings(object sender, RoutedEventArgs e)
    {
        HideFlyout();
        _app.ShowDashboard(page: DashboardPage.Settings);
    }

    private void OnQuit(object sender, RoutedEventArgs e)
    {
        HideFlyout();
        _ = _app.QuitAsync();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X, Y; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out NativePoint point);
}
