namespace WireTunnels.Client;

/// Port of AppPaths.swift: everything the app stores for the current user lives under one root,
/// `%LOCALAPPDATA%\WireTunnels`, which only that user can read.
public sealed class AppPaths(string root)
{
    public static AppPaths ForCurrentUser() =>
        new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WireTunnels"));

    public string Root { get; } = root;
    /// `<alias>.conf.dpapi`: configs encrypted for the current user.
    public string Configs => Path.Combine(Root, "configs");
    public string Metadata => Path.Combine(Root, "metadata");
    public string TunnelsFile => Path.Combine(Metadata, "tunnels.json");
    public string SettingsFile => Path.Combine(Root, "settings.json");
    public string Logs => Path.Combine(Root, "logs");
    public string LogFile => Path.Combine(Logs, "WireTunnels.log");
}
