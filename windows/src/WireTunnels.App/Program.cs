using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace WireTunnels.App;

/// Owns Main so a second launch hands over to the running instance (the macOS app is single
/// instance too): double-clicking the shortcut again just brings the dashboard forward.
public static partial class Program
{
    /// Passed by the login Run entry: start in the tray without opening the dashboard.
    public const string BackgroundArgument = "--background";

    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        // One instance per data folder: a UI test's app never hands over to the user's own.
        var key = Environment.GetEnvironmentVariable(Client.AppPaths.DataDirectoryVariable) is { Length: > 0 } data
            ? "WireTunnels.App:" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(data).ToLowerInvariant())))[..16]
            : "WireTunnels.App";
        var instance = AppInstance.FindOrRegisterForKey(key);
        if (!instance.IsCurrent)
        {
            // Let the running instance take the foreground, then forward this activation to it.
            AllowSetForegroundWindow(instance.ProcessId);
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            Task.Run(() => instance.RedirectActivationToAsync(activation).AsTask()).Wait();
            return 0;
        }

        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(instance, args.Contains(BackgroundArgument, StringComparer.OrdinalIgnoreCase));
        });
        return 0;
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(uint processId);
}
