using WireTunnels.Core.Config;

namespace WireTunnels.Core.Net;

public static class IPFamilyExtensions
{
    public static string DisplayName(this IPFamily family) => family == IPFamily.IPv4 ? "IPv4" : "IPv6";
    public static string DefaultRoute(this IPFamily family) => family == IPFamily.IPv4 ? "0.0.0.0/0" : "::/0";
}

/// The routing a tunnel was connected with, which can differ from its saved config until it reconnects.
public sealed record TunnelRouting(IReadOnlyList<string> Address, IReadOnlyList<string> AllowedIPs, IReadOnlyList<string> Dns);

public enum IPFamilyLeakReason
{
    /// Routes all of the family but has no address of it, so its traffic never uses the tunnel.
    MissingAddress,
    /// Routes all of the other family only, on a network that has this one.
    NotRouted,
    /// The config is right, but the routing table still sends the family elsewhere.
    RouteBypassed,
}

/// Port of IPFamilyLeak.swift.
public sealed record IPFamilyLeak(IPFamily Family, IPFamilyLeakReason Reason)
{
    public string Title => $"{Family.DisplayName()} is leaking";

    public string Problem
    {
        get
        {
            var name = Family.DisplayName();
            return Reason switch
            {
                IPFamilyLeakReason.MissingAddress => $"This tunnel has no {name} address, so {name} traffic goes around it.",
                IPFamilyLeakReason.NotRouted => $"This tunnel does not route {name}, and this network has {name}, so {name} traffic goes around it.",
                _ => $"The tunnel is set to route all {name} traffic, but Windows sends it around the tunnel.",
            };
        }
    }

    public string? FixDescription
    {
        get
        {
            var name = Family.DisplayName();
            return Reason switch
            {
                IPFamilyLeakReason.MissingAddress => $"The fix disables {name} for this tunnel by adding a placeholder {name} address.",
                IPFamilyLeakReason.NotRouted => $"The fix disables {name} for this tunnel by routing it into the tunnel with a placeholder address.",
                _ => null,
            };
        }
    }
}

public sealed record IPFamilyLeakInput(Guid Id, TunnelRouting Routing, bool Acknowledged);

/// A leak is traffic reaching the physical network while a route-all tunnel is up. Traffic carried by
/// another connected tunnel is not a leak. Acknowledging a tunnel silences its warning, not the facts.
public static class IPFamilyLeakDetector
{
    public static IReadOnlyDictionary<Guid, IReadOnlyList<IPFamilyLeak>> Leaks(IReadOnlyList<IPFamilyLeakInput> connected,
        IReadOnlySet<IPFamily> physicalFamilies, IReadOnlySet<IPFamily> routeBypassedFamilies, bool killSwitchArmed)
    {
        var result = new Dictionary<Guid, IReadOnlyList<IPFamilyLeak>>();
        // The kill switch's filters drop everything outside the tunnel adapters.
        if (killSwitchArmed) return result;
        bool RoutesAll(IPFamily f, IPFamilyLeakInput i) => IPFamilyRouting.RoutesAll(f, i.Routing.AllowedIPs);
        bool HasAddress(IPFamily f, IPFamilyLeakInput i) => IPFamilyRouting.HasAddress(f, i.Routing.Address);
        var families = Enum.GetValues<IPFamily>();
        var covered = families.Where(f => connected.Any(i => RoutesAll(f, i) && HasAddress(f, i))).ToHashSet();

        foreach (var input in connected)
        {
            var leaks = new List<IPFamilyLeak>();
            foreach (var family in families)
            {
                var other = family == IPFamily.IPv4 ? IPFamily.IPv6 : IPFamily.IPv4;
                if (RoutesAll(family, input))
                {
                    if (!HasAddress(family, input))
                    {
                        if (!covered.Contains(family)) leaks.Add(new(family, IPFamilyLeakReason.MissingAddress));
                    }
                    else if (routeBypassedFamilies.Contains(family)) leaks.Add(new(family, IPFamilyLeakReason.RouteBypassed));
                }
                else if (RoutesAll(other, input) && physicalFamilies.Contains(family) && !covered.Contains(family))
                    leaks.Add(new(family, IPFamilyLeakReason.NotRouted));
            }
            if (leaks.Count > 0) result[input.Id] = leaks;
        }
        return result;
    }

    public static IReadOnlyDictionary<Guid, IReadOnlyList<IPFamilyLeak>> Warnings(
        IReadOnlyDictionary<Guid, IReadOnlyList<IPFamilyLeak>> leaks, IReadOnlyList<IPFamilyLeakInput> connected)
    {
        var acknowledged = connected.Where(i => i.Acknowledged).Select(i => i.Id).ToHashSet();
        return leaks.Where(l => !acknowledged.Contains(l.Key)).ToDictionary(l => l.Key, l => l.Value);
    }

    /// What a route-all tunnel really carries, or null when it routes neither family in full.
    public static string? RouteLabel(IEnumerable<string> allowedIPs, IEnumerable<IPFamilyLeak> leaks)
    {
        var routed = IPFamilyRouting.RoutedAllFamilies(allowedIPs).Except(leaks.Select(l => l.Family)).ToHashSet();
        return routed.Count switch
        {
            2 => "All traffic (IPv4+IPv6)",
            1 when routed.Contains(IPFamily.IPv4) => "All IPv4 traffic",
            1 => "All IPv6 traffic",
            _ => null,
        };
    }
}

/// Port of IPFamilyLeakFix.swift: stops a leaking family by giving the tunnel a placeholder address
/// of it, so its routes take effect and the server drops the traffic.
public static class IPFamilyLeakFix
{
    public enum UnavailableReason { RouteBypassed, Managed, InventoryProtected, Busy, DnsUsesFamily }

    public static UnavailableReason? Unavailable(IPFamilyLeak leak, IEnumerable<string> dns, bool isManaged, bool hasInventory, bool isBusy)
    {
        if (leak.Reason == IPFamilyLeakReason.RouteBypassed) return UnavailableReason.RouteBypassed;
        if (isManaged) return UnavailableReason.Managed;
        if (hasInventory) return UnavailableReason.InventoryProtected;
        if (isBusy) return UnavailableReason.Busy;
        // Routing the family into the tunnel would drop every DNS query.
        var servers = WireGuardDns.Servers(dns);
        if (servers.Count > 0 && servers.All(s => IPFamilyRouting.FamilyOf(s) == leak.Family)) return UnavailableReason.DnsUsesFamily;
        return null;
    }

    public static string DnsUnavailableMessage(IPFamily family) =>
        $"The fix is not available because this tunnel's DNS servers use {family.DisplayName()}.";

    /// IPv6: a random RFC 4193 /48. IPv4: a random host in 198.18.0.0/15, which real LANs and VPNs do not use.
    public static string PlaceholderAddress(IPFamily family, Random random)
    {
        if (family == IPFamily.IPv6)
        {
            var id = new byte[5];
            random.NextBytes(id);
            return $"fd{id[0]:x2}:{id[1] << 8 | id[2]:x}:{id[3] << 8 | id[4]:x}::1/128";
        }
        return $"198.{random.Next(18, 20)}.{random.Next(0, 256)}.{random.Next(1, 255)}/32";
    }

    public static string MarkerComment(IPFamily family)
    {
        var name = family.DisplayName();
        return $"# Placeholder address added by WireTunnels to keep {name} from leaking. Remove it once the tunnel has a real {name} address.";
    }

    /// Adds the placeholder address and the family's default route only where they are missing.
    /// Every other line is kept byte for byte.
    public static string Apply(string config, IPFamily family, string placeholder)
    {
        var lines = config.Split('\n').ToList();
        var lineEnd = lines[0].EndsWith('\r') ? "\r" : "";
        string section = "";
        var peerCount = 0;
        int? interfaceHeader = null, addressLine = null, allowedIPsLine = null;
        var addresses = new List<string>();
        var allowedIPs = new List<string>();
        for (var index = 0; index < lines.Count; index++)
        {
            var line = lines[index].Trim();
            if (line.StartsWith('['))
            {
                section = line.ToLowerInvariant();
                if (section == "[peer]") peerCount++;
                if (section == "[interface]") interfaceHeader ??= index;
                continue;
            }
            var equals = line.IndexOf('=');
            if (line.StartsWith('#') || equals < 0) continue;
            var key = line[..equals].Trim().ToLowerInvariant();
            var value = line[(equals + 1)..];
            var hash = value.IndexOf('#');
            var values = (hash >= 0 ? value[..hash] : value).Split(',').Select(v => v.Trim()).Where(v => v.Length > 0);
            if (section == "[interface]" && key == "address")
            {
                addressLine ??= index;
                addresses.AddRange(values);
            }
            else if (section == "[peer]" && peerCount == 1 && key == "allowedips")
            {
                allowedIPsLine ??= index;
                allowedIPs.AddRange(values);
            }
        }

        // AllowedIPs first, so inserting the comment above Address cannot shift its index.
        if (!IPFamilyRouting.RoutesAll(family, allowedIPs) && allowedIPsLine is { } allowedIndex)
            lines[allowedIndex] = Appending(family.DefaultRoute(), lines[allowedIndex]);
        if (!IPFamilyRouting.HasAddress(family, addresses))
        {
            if (addressLine is { } index)
            {
                lines[index] = Appending(placeholder, lines[index]);
                lines.Insert(index, MarkerComment(family) + lineEnd);
            }
            else if (interfaceHeader is { } header)
                lines.InsertRange(header + 1, [MarkerComment(family) + lineEnd, $"Address = {placeholder}{lineEnd}"]);
        }
        return string.Join('\n', lines);
    }

    private static string Appending(string value, string line)
    {
        var lineEnd = line.EndsWith('\r') ? "\r" : "";
        var body = lineEnd.Length == 0 ? line : line[..^1];
        var comment = "";
        var hash = body.IndexOf('#');
        if (hash >= 0)
        {
            comment = " " + body[hash..];
            body = body[..hash];
        }
        return body.TrimEnd() + ", " + value + comment + lineEnd;
    }
}
