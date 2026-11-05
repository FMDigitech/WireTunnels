using WireTunnels.Core.Config;
using WireTunnels.Core.Net;

namespace WireTunnels.Core.Models;

public enum TunnelWarningKind { MultipleFullTunnels, OverlappingAllowedIPs, ConflictingDns, KillSwitchBlocking }

public sealed record TunnelWarning(TunnelWarningKind Kind, IReadOnlyList<string> TunnelNames)
{
    public string Id => $"{Kind}-{string.Join("-", TunnelNames)}";

    public string Title => Kind switch
    {
        TunnelWarningKind.MultipleFullTunnels => "Multiple Full Tunnels",
        TunnelWarningKind.OverlappingAllowedIPs => "Overlapping Routes",
        TunnelWarningKind.ConflictingDns => "DNS Conflict",
        _ => "Kill Switch Active",
    };

    public string Message => Kind switch
    {
        TunnelWarningKind.MultipleFullTunnels =>
            $"Multiple full-tunnel VPNs active: {string.Join(", ", TunnelNames)}. This may break routing or DNS.",
        TunnelWarningKind.OverlappingAllowedIPs =>
            $"Tunnels \"{TunnelNames[0]}\" and \"{TunnelNames[1]}\" have overlapping AllowedIPs. Traffic may be routed incorrectly.",
        TunnelWarningKind.ConflictingDns =>
            $"Active tunnels {string.Join(", ", TunnelNames)} define different DNS servers. Resolution may be unpredictable.",
        _ => $"\"{TunnelNames[0]}\" dropped unexpectedly. All non-tunnel traffic is blocked until it reconnects or you disable its kill switch.",
    };
}

/// Port of TunnelManager.updateWarnings (IP-family leak warnings follow in the network-parity phase).
public static class TunnelWarnings
{
    public static IReadOnlyList<TunnelWarning> Compute(IReadOnlyList<Tunnel> tunnels, IReadOnlySet<Guid> killSwitchArmedIds)
    {
        var warnings = new List<TunnelWarning>();
        var active = tunnels.Where(t => t.IsActive).ToList();

        var full = active.Where(t => IPFamilyRouting.RoutesAll(IPFamily.IPv4, t.AllowedIPs)).Select(t => t.Name).ToList();
        if (full.Count > 1) warnings.Add(new(TunnelWarningKind.MultipleFullTunnels, full));

        // Compared by parsed prefix (macOS compares strings): 10.0.0.0/8 overlaps 10.1.0.0/16.
        for (var i = 0; i < active.Count; i++)
        for (var j = i + 1; j < active.Count; j++)
            if (Prefixes(active[i]).Any(a => Prefixes(active[j]).Any(a.Overlaps)))
                warnings.Add(new(TunnelWarningKind.OverlappingAllowedIPs, [active[i].Name, active[j].Name]));

        var withDns = active.Where(t => WireGuardDns.Servers(t.Dns).Count > 0).ToList();
        if (withDns.Count > 1)
        {
            var sets = withDns.Select(t => WireGuardDns.Servers(t.Dns).ToHashSet()).ToList();
            if (!sets.Skip(1).All(s => s.SetEquals(sets[0])))
                warnings.Add(new(TunnelWarningKind.ConflictingDns, withDns.Select(t => t.Name).ToList()));
        }

        foreach (var t in tunnels.Where(t => killSwitchArmedIds.Contains(t.Id) && !t.IsActive))
            warnings.Add(new(TunnelWarningKind.KillSwitchBlocking, [t.Name]));

        return warnings;
    }

    private static IEnumerable<IPPrefix> Prefixes(Tunnel t) =>
        t.AllowedIPs.Select(s => IPPrefix.TryParse(s, out var p) ? (IPPrefix?)p : null).OfType<IPPrefix>();
}
