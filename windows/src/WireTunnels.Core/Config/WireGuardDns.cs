namespace WireTunnels.Core.Config;

/// Port of WireGuardDNS: a `DNS =` entry that is not an IP address is a search domain.
public static class WireGuardDns
{
    public static bool IsAddress(string value) =>
        value.Contains(':') || (value.Length > 0 && value.All(c => c == '.' || char.IsAsciiDigit(c)));

    public static IReadOnlyList<string> Servers(IEnumerable<string> entries) => entries.Where(IsAddress).ToList();

    public static IReadOnlyList<string> SearchDomains(IEnumerable<string> entries) =>
        entries.Where(e => !IsAddress(e)).ToList();

    /// Lower-cased domain without a wildcard or dots at the ends, or null when it is not a valid name.
    public static string? NormalizedDomain(string raw)
    {
        var domain = raw.Trim().ToLowerInvariant();
        if (domain.StartsWith("*.", StringComparison.Ordinal)) domain = domain[2..];
        domain = domain.Trim('.');
        if (domain.Length is 0 or > 253) return null;
        foreach (var label in domain.Split('.'))
        {
            if (label.Length is 0 or > 63 || label.StartsWith('-') || label.EndsWith('-')) return null;
            if (!label.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c) || c == '-')) return null;
        }
        return domain;
    }

    /// The `DNS =` value for typed servers and search domains; invalid domains are left out and reported.
    public static (string Line, IReadOnlyList<string> InvalidDomains) Compose(string servers, string searchDomains)
    {
        static string[] Entries(string text) =>
            text.Split((char[])[',', ' ', '\t', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries);

        var seen = new HashSet<string>();
        var invalid = new List<string>();
        var domains = new List<string>();
        foreach (var entry in Entries(searchDomains))
        {
            if (NormalizedDomain(entry) is not { } domain) { invalid.Add(entry); continue; }
            if (seen.Add(domain)) domains.Add(domain);
        }
        return (string.Join(", ", Entries(servers).Concat(domains)), invalid);
    }
}
