namespace WireTunnels.Client;

/// Port of AppPaths.swift: everything the app stores for the current user lives under one root,
/// `%LOCALAPPDATA%\WireTunnels`, which only that user can read.
public sealed class AppPaths(string root)
{
    /// Set by the UI tests, so they never touch the user's own tunnels.
    public const string DataDirectoryVariable = "WIRETUNNELS_DATA_DIR";

    public static AppPaths ForCurrentUser() =>
        new(Environment.GetEnvironmentVariable(DataDirectoryVariable) is { Length: > 0 } custom
            ? Path.GetFullPath(custom)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WireTunnels"));

    public string Root { get; } = root;
    /// `<alias>.conf.dpapi`: configs encrypted for the current user.
    public string Configs => Path.Combine(Root, "configs");
    public string Metadata => Path.Combine(Root, "metadata");
    public string TunnelsFile => Path.Combine(Metadata, "tunnels.json");
    public string HopChainsFile => Path.Combine(Metadata, "hopchains.json");
    public string SettingsFile => Path.Combine(Root, "settings.json");
    /// Written by the update command line (`ok` / `fail`), read at the next start.
    public string UpdateResultFile => Path.Combine(Root, "update-result.txt");
    public string Logs => Path.Combine(Root, "logs");
    public string LogFile => Path.Combine(Logs, "WireTunnels.log");
}
