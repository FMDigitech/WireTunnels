namespace WireTunnels.Core.Net;

public enum IPFamily { IPv4, IPv6 }

/// Port of IPFamilyRouting: AllowedIPs and Address entries compared by parsed bytes, so `0::/0` matches `::/0`.
public static class IPFamilyRouting
{
    private static IPPrefix? ParseEntry(string entry)
    {
        // wg-quick drops everything from "#"; the config parser keeps it in the value.
        var hash = entry.IndexOf('#');
        var text = (hash >= 0 ? entry[..hash] : entry).Trim();
        var slash = text.IndexOf('/');
        var host = slash >= 0 ? text[..slash] : text;
        var percent = host.IndexOf('%');
        if (percent >= 0) text = host[..percent] + (slash >= 0 ? text[slash..] : "");
        return IPPrefix.TryParse(text, out var prefix) ? prefix : null;
    }

    public static IPFamily? FamilyOf(string entry) => ParseEntry(entry) is { } p ? Family(p) : null;

    private static IPFamily Family(IPPrefix p) => p.IsIPv4 ? IPFamily.IPv4 : IPFamily.IPv6;

    /// The family's default route, or both of its /1 halves as wg-quick installs them.
    public static bool RoutesAll(IPFamily family, IEnumerable<string> allowedIPs)
    {
        var halves = new HashSet<byte>();
        foreach (var entry in allowedIPs)
        {
            if (ParseEntry(entry) is not { } p || Family(p) != family) continue;
            if (p.Length == 0) return true;
            if (p.Length == 1) halves.Add((byte)(p.Bytes[0] & 0x80));
        }
        return halves.Count == 2;
    }

    public static IReadOnlySet<IPFamily> RoutedAllFamilies(IEnumerable<string> allowedIPs)
    {
        var list = allowedIPs.ToList();
        return Enum.GetValues<IPFamily>().Where(f => RoutesAll(f, list)).ToHashSet();
    }

    public static bool HasAddress(IPFamily family, IEnumerable<string> addresses) =>
        addresses.Any(a => ParseEntry(a) is { } p && Family(p) == family);

    /// Families the physical network can reach the internet with: global unicast IPv6
    /// (2000::/3) and any IPv4 address outside link-local 169.254.0.0/16.
    public static IReadOnlySet<IPFamily> InternetFamilies(IEnumerable<string> physicalAddresses)
    {
        var families = new HashSet<IPFamily>();
        foreach (var entry in physicalAddresses)
        {
            if (ParseEntry(entry) is not { } p) continue;
            if (p.IsIPv4 && !(p.Bytes[0] == 169 && p.Bytes[1] == 254)) families.Add(IPFamily.IPv4);
            if (!p.IsIPv4 && (p.Bytes[0] & 0xE0) == 0x20) families.Add(IPFamily.IPv6);
        }
        return families;
    }
}
