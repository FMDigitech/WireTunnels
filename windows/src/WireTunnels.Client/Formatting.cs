using System.Globalization;

namespace WireTunnels.Client;

/// Port of the formatBytes / formatDuration / formatHandshake helpers of TunnelDetailView.swift.
public static class Formatting
{
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    public static string Bytes(long bytes)
    {
        var abs = Math.Abs(bytes);
        return abs switch
        {
            < 1024 => $"{bytes} B",
            < 1024 * 1024 => (bytes / 1024.0).ToString("0.0", Invariant) + " KB",
            < 1024L * 1024 * 1024 => (bytes / 1048576.0).ToString("0.00", Invariant) + " MB",
            _ => (bytes / 1073741824.0).ToString("0.00", Invariant) + " GB",
        };
    }

    public static string Rate(double bytesPerSecond) => Bytes((long)bytesPerSecond) + "/s";

    public static string Duration(DateTimeOffset since, DateTimeOffset now)
    {
        var s = Math.Max(0, (long)(now - since).TotalSeconds);
        if (s < 60) return $"{s}s";
        if (s < 3600) return $"{s / 60}m {s % 60}s";
        return $"{s / 3600}h {s % 3600 / 60}m";
    }

    public static string Handshake(DateTimeOffset? when, DateTimeOffset now)
    {
        if (when is not { } date) return "Never";
        var elapsed = (now - date).TotalSeconds;
        static string Plural(long n, string unit) => $"{n} {unit}{(n == 1 ? "" : "s")} ago";
        return elapsed switch
        {
            < 0 => "Just now",
            < 60 => Plural((long)elapsed, "second"),
            < 3600 => Plural((long)(elapsed / 60), "minute"),
            < 86400 => Plural((long)(elapsed / 3600), "hour"),
            _ => Plural((long)(elapsed / 86400), "day"),
        };
    }

    /// The menu-bar style summary of a tunnel's networks.
    public static string Networks(IReadOnlyList<string> allowedIPs) => allowedIPs.Count switch
    {
        0 => "",
        1 => allowedIPs[0],
        2 => string.Join(", ", allowedIPs),
        _ => $"{allowedIPs[0]} +{allowedIPs.Count - 1} more",
    };
}
