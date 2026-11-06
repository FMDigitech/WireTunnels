using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.Win32;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using WireTunnels.Client;

namespace WireTunnels.App.Services;

/// Toasts through the Windows App SDK (macOS NotificationService). Unpackaged apps register at
/// startup; if Windows refuses, notifications are logged and skipped.
public sealed class ToastNotifier(LogService log) : INotifier, IDisposable
{
    private bool _registered;

    public event Action? Invoked;

    public void Register()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, _) => Invoked?.Invoke();
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            log.Warning($"Notifications are unavailable: {e.Message}");
        }
    }

    public void Post(string title, string body)
    {
        if (!_registered) return;
        try
        {
            AppNotificationManager.Default.Show(new AppNotificationBuilder().AddText(title).AddText(body).BuildNotification());
        }
        catch (COMException e)
        {
            log.Warning($"Unable to show a notification: {e.Message}");
        }
    }

    public void Dispose()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); }
        catch (COMException) { }
        _registered = false;
    }
}

/// Launch at login through the per-user Run key (macOS SMAppService.mainApp).
public static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "WireTunnels";

    private static string Command => $"\"{Environment.ProcessPath}\" {Program.BackgroundArgument}";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string value && value.Contains(Environment.ProcessPath ?? "\0", StringComparison.OrdinalIgnoreCase);
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled) key.SetValue(ValueName, Command);
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

/// Starts the stopped service through UAC (the setup wizard's "Start Service"). Installing it is
/// the installer's job (phase 7); until then the wizard explains the manual steps.
public static class ServiceControl
{
    /// False when the user declined the UAC prompt.
    public static async Task<bool> StartElevatedAsync()
    {
        var start = new ProcessStartInfo("sc.exe", $"start {WindowsServiceProbe.ServiceName}")
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        try
        {
            using var process = Process.Start(start);
            if (process is null) return false;
            await process.WaitForExitAsync();
            return true;
        }
        catch (Win32Exception e) when (e.NativeErrorCode == 1223) // ERROR_CANCELLED
        {
            return false;
        }
    }
}

public static partial class WindowExtensions
{
    public static IntPtr Handle(this Window window) => WinRT.Interop.WindowNative.GetWindowHandle(window);

    public static AppWindow AppWindowOf(this Window window) =>
        AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(window.Handle()));

    public static double Scale(this Window window) => GetDpiForWindow(window.Handle()) / 96.0;

    public static void SetIcon(this Window window) =>
        window.AppWindowOf().SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico"));

    /// Brings a hidden or minimized window to the front.
    public static void Present(this Window window)
    {
        var appWindow = window.AppWindowOf();
        if (appWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        appWindow.Show();
        window.Activate();
        SetForegroundWindow(window.Handle());
    }

    public static void CenterOnScreen(this Window window, int widthDip, int heightDip)
    {
        var appWindow = window.AppWindowOf();
        var area = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = window.Scale();
        var w = Math.Min((int)(widthDip * scale), area.Width);
        var h = Math.Min((int)(heightDip * scale), area.Height);
        appWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h));
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr hwnd);
}
