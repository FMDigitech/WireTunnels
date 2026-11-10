using WireTunnels.Core.Storage;

namespace WireTunnels.Client;

/// User preferences (the macOS UserDefaults keys of SettingsView). Launch at login lives in the
/// registry Run key instead, because Windows reads it from there.
public sealed class AppSettings
{
    public bool StartInBackground { get; set; }
    public bool ShowNotifications { get; set; } = true;
    public bool CheckForUpdates { get; set; } = true;
}

public sealed class AppSettingsStore(string file)
{
    private readonly RecoverableJsonStore<AppSettings> _store = new(file, () => new AppSettings());

    public AppSettings Load()
    {
        try { return _store.Load(); }
        catch (IOException) { return new AppSettings(); } // preferences are not worth blocking startup
    }

    public void Save(AppSettings settings) => _store.Save(settings);
}

/// Toast notifications (macOS NotificationService); the app implements it with AppNotificationManager.
public interface INotifier
{
    void Post(string title, string body);
}

public static class Notifications
{
    public static void Connected(this INotifier n, string tunnel) => n.Post("Tunnel Connected", $"{tunnel} connected successfully.");
    public static void Disconnected(this INotifier n, string tunnel) => n.Post("Tunnel Disconnected", $"{tunnel} disconnected.");
    public static void Failed(this INotifier n, string tunnel, string message) => n.Post("Tunnel Error", $"{tunnel}: {message}");
}

public sealed class NullNotifier : INotifier
{
    public void Post(string title, string body) { }
}
