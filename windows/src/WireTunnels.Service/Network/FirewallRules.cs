using System.Net;
using System.Net.Sockets;
using WireTunnels.Core.Net;

namespace WireTunnels.Service.Network;

/// One kill-switch exception: the tunnel adapter (absent while the tunnel is down) and its peer endpoint.
internal sealed record KillSwitchRule(ulong? Luid, IPAddress Endpoint, int Port);

/// Full-tunnel DNS leak guard: DNS may only go to the tunnel's own servers.
internal sealed record DnsGuard(IReadOnlyList<IPAddress> Servers);

/// One inventory policy's protected destinations, the adapter that may carry them (null: blocked
/// everywhere) and the endpoint its tunnel needs to reach.
internal sealed record InventoryGuard(IReadOnlyList<IPPrefix> Prefixes, ulong? AllowedLuid, IPEndPoint? Endpoint);

internal enum WfpLayer{ ConnectV4, ConnectV6, RecvAcceptV4, RecvAcceptV6 }

internal enum WfpField { LocalInterface, RemoteAddress, RemotePrefix, RemotePort, LocalPort, Protocol, Flags, IcmpType }

/// A condition value: a number (ports, protocol, flags, LUID) or an address. Same-field
/// conditions are OR-ed by WFP, different fields AND-ed.
internal sealed record WfpCondition(WfpField Field, ulong Number = 0, IPAddress? Address = null, IPPrefix? Prefix = null, bool NotEqual = false);

internal sealed record WfpFilter(string Name, WfpLayer Layer, byte Weight, bool Permit, IReadOnlyList<WfpCondition> Conditions);

/// The WFP equivalent of the macOS pf anchor (KillSwitchEntry.rules): pure, so it is tested on any OS.
/// All filters live in the WireTunnels sublayer; inside it the highest weight wins.
internal static class FirewallRules
{
    private const byte Udp = 17, IcmpV6 = 58;
    // WFP accepts FWP_UINT8 weights 0-15; the highest matching filter decides inside our sublayer.
    private const byte DnsPermit = 15, EndpointPermit = 15, DnsBlock = 14, InventoryBlock = 13, Permit = 12, Block = 0;
    public const int InventoryChunk = 256;
    public const uint FlagIsLoopback = 0x1;

    private static readonly WfpLayer[] All = [WfpLayer.ConnectV4, WfpLayer.ConnectV6, WfpLayer.RecvAcceptV4, WfpLayer.RecvAcceptV6];

    private static bool IsV6(WfpLayer layer) => layer is WfpLayer.ConnectV6 or WfpLayer.RecvAcceptV6;
    private static bool IsConnect(WfpLayer layer) => layer is WfpLayer.ConnectV4 or WfpLayer.ConnectV6;

    /// Blocks everything but loopback, DHCP/NDP (so the physical link keeps working), the tunnel
    /// adapters and each peer endpoint over UDP. ALE layers are stateful: replies on an allowed flow pass.
    /// An empty list means no kill switch at all (the macOS helper flushes its anchor).
    public static IReadOnlyList<WfpFilter> KillSwitch(IReadOnlyList<KillSwitchRule> rules)
    {
        if (rules.Count == 0) return [];
        var filters = new List<WfpFilter>();
        foreach (var layer in All)
        {
            filters.Add(new("Block all", layer, Block, false, []));
            filters.Add(new("Permit loopback", layer, Permit, true, [new(WfpField.Flags, FlagIsLoopback)]));
        }
        foreach (var layer in new[] { WfpLayer.ConnectV4, WfpLayer.RecvAcceptV4 })
            filters.Add(new("Permit DHCP", layer, Permit, true,
                [new(WfpField.Protocol, Udp), new(WfpField.LocalPort, 68), new(WfpField.RemotePort, 67)]));
        foreach (var layer in new[] { WfpLayer.ConnectV6, WfpLayer.RecvAcceptV6 })
        {
            filters.Add(new("Permit DHCPv6", layer, Permit, true,
                [new(WfpField.Protocol, Udp), new(WfpField.LocalPort, 546), new(WfpField.RemotePort, 547)]));
            // Router/neighbor solicitation and advertisement, redirect: without them IPv6 on the LAN breaks.
            filters.Add(new("Permit NDP", layer, Permit, true,
                [new(WfpField.Protocol, IcmpV6), .. Enumerable.Range(133, 5).Select(t => new WfpCondition(WfpField.IcmpType, (ulong)t))]));
        }
        foreach (var rule in rules.DistinctBy(r => (r.Luid, r.Endpoint, r.Port)))
        {
            if (rule.Luid is { } luid)
                filters.AddRange(All.Select(layer => new WfpFilter("Permit tunnel adapter", layer, Permit, true, [new(WfpField.LocalInterface, luid)])));
            var v6 = rule.Endpoint.AddressFamily == AddressFamily.InterNetworkV6;
            foreach (var layer in All.Where(l => IsV6(l) == v6))
                filters.Add(new("Permit WireGuard endpoint", layer, Permit, true,
                    [new(WfpField.Protocol, Udp), new(WfpField.RemoteAddress, Address: rule.Endpoint), new(WfpField.RemotePort, (ulong)rule.Port)]));
        }
        return filters;
    }

    /// Inventory protection (port of InventoryRoutingService.installGuard): each policy's destinations are
    /// blocked in both directions everywhere but its own tunnel adapter, and everywhere while that tunnel is
    /// down. The block outranks the kill switch's adapter permit, so another tunnel cannot carry them; traffic
    /// on the right adapter matches nothing here and falls through to the kill switch, as on macOS. The peer
    /// endpoint stays reachable over UDP so the tunnel can (re)connect.
    public static IReadOnlyList<WfpFilter> Inventory(IReadOnlyList<InventoryGuard> guards)
    {
        var filters = new List<WfpFilter>();
        foreach (var guard in guards)
        {
            if (guard.Endpoint is { } endpoint)
            {
                var v6 = endpoint.AddressFamily == AddressFamily.InterNetworkV6;
                filters.Add(new("Permit inventory tunnel endpoint", v6 ? WfpLayer.ConnectV6 : WfpLayer.ConnectV4, EndpointPermit, true,
                    [new(WfpField.Protocol, Udp), new(WfpField.RemoteAddress, Address: endpoint.Address), new(WfpField.RemotePort, (ulong)endpoint.Port)]));
            }
            foreach (var layer in All)
            {
                var family = guard.Prefixes.Where(p => p.IsIPv4 != IsV6(layer)).ToList();
                // shortcut: fixed chunks of OR-ed prefixes per filter; measure WFP limits before inventories of 100k+ entries.
                foreach (var chunk in family.Chunk(InventoryChunk))
                {
                    List<WfpCondition> conditions = [.. chunk.Select(p => new WfpCondition(WfpField.RemotePrefix, Prefix: p))];
                    if (guard.AllowedLuid is { } luid) conditions.Add(new(WfpField.LocalInterface, luid, NotEqual: true));
                    filters.Add(new("Block inventory destinations outside their tunnel", layer, InventoryBlock, false, conditions));
                }
            }
        }
        return filters;
    }

    /// Windows asks every interface's DNS servers in parallel, so a full tunnel alone leaks queries.
    /// Port 53 is blocked except towards the tunnels' servers and loopback (a local resolver).
    public static IReadOnlyList<WfpFilter> DnsGuards(IReadOnlyList<DnsGuard> guards)
    {
        var servers = guards.SelectMany(g => g.Servers).Distinct().ToList();
        if (servers.Count == 0) return [];
        var filters = new List<WfpFilter>();
        foreach (var layer in All.Where(IsConnect))
        {
            var family = IsV6(layer) ? AddressFamily.InterNetworkV6 : AddressFamily.InterNetwork;
            filters.Add(new("Block DNS outside the tunnel", layer, DnsBlock, false, [new(WfpField.RemotePort, 53)]));
            filters.Add(new("Permit loopback DNS", layer, DnsPermit, true, [new(WfpField.Flags, FlagIsLoopback), new(WfpField.RemotePort, 53)]));
            var own = servers.Where(s => s.AddressFamily == family).ToList();
            if (own.Count > 0)
                filters.Add(new("Permit tunnel DNS", layer, DnsPermit, true,
                    [new(WfpField.RemotePort, 53), .. own.Select(s => new WfpCondition(WfpField.RemoteAddress, Address: s))]));
        }
        return filters;
    }
}
