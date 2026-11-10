namespace WireTunnels.Contracts;

public enum AppLinkAction { Connect, Disconnect, DisconnectAll, Show }

/// `wiretunnels://connect?name=Office`, `disconnect?name=…`, `disconnect-all`, `show`: what macOS exposes as App
/// Intents (Shortcuts), for the CLI, scripts and shortcuts. Only saved tunnels, by display name; nothing is imported.
public sealed record AppLink(AppLinkAction Action, string? Name = null)
{
    public const string Scheme = "wiretunnels";

    public static AppLink? Parse(string? text)
    {
        if (text is null || !Uri.TryCreate(text.Trim(), UriKind.Absolute, out var uri)
            || !uri.Scheme.Equals(Scheme, StringComparison.OrdinalIgnoreCase)) return null;
        AppLinkAction? action = uri.Host.ToLowerInvariant() switch
        {
            "connect" => AppLinkAction.Connect,
            "disconnect" => AppLinkAction.Disconnect,
            "disconnect-all" => AppLinkAction.DisconnectAll,
            "show" => AppLinkAction.Show,
            _ => null,
        };
        if (action is not { } a) return null;
        var name = uri.Query.TrimStart('?').Split('&')
            .Select(p => p.Split('=', 2))
            .Where(p => p.Length == 2 && p[0].Equals("name", StringComparison.OrdinalIgnoreCase))
            .Select(p => Uri.UnescapeDataString(p[1].Replace('+', ' ')).Trim())
            .FirstOrDefault();
        if (a is AppLinkAction.Connect or AppLinkAction.Disconnect && string.IsNullOrEmpty(name)) return null;
        return new AppLink(a, a is AppLinkAction.Connect or AppLinkAction.Disconnect ? name : null);
    }

    public override string ToString() => Action switch
    {
        AppLinkAction.DisconnectAll => $"{Scheme}://disconnect-all",
        AppLinkAction.Show => $"{Scheme}://show",
        _ => $"{Scheme}://{Action.ToString().ToLowerInvariant()}?name={Uri.EscapeDataString(Name ?? "")}",
    };
}
