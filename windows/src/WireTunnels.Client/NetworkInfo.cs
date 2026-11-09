using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using WireTunnels.Core.Net;

namespace WireTunnels.Client;

/// What the app reads from the local network stack (unprivileged); faked in tests.
public interface INetworkInfo
{
    /// Unicast addresses of the interfaces that are up, other than loopback and our tunnel adapters.
    IReadOnlyList<string> PhysicalAddresses(IReadOnlySet<string> tunnelAdapters);
    /// Of `families`, those whose public traffic the routing table sends outside every tunnel adapter.
    /// A failed lookup counts as unknown, not as a leak.
    IReadOnlySet<IPFamily> BypassedFamilies(IReadOnlySet<IPFamily> families, IReadOnlySet<string> tunnelAdapters);
    Task<IPAddress?> ResolveAsync(string host, CancellationToken ct = default);
}

/// Port of RouteLookupService and the physical-address part of NetworkMonitorService.
public sealed class SystemNetworkInfo : INetworkInfo
{
    /// One destination per /1 half that carries public traffic (2000::/3 lies in ::/1). Lookups send nothing.
    private static readonly Dictionary<IPFamily, string[]> Probes = new()
    {
        [IPFamily.IPv4] = ["1.1.1.1", "149.112.112.112"],
        [IPFamily.IPv6] = ["2606:4700:4700::1111"],
    };

    public IReadOnlyList<string> PhysicalAddresses(IReadOnlySet<string> tunnelAdapters) =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(i => i.OperationalStatus == OperationalStatus.Up && i.NetworkInterfaceType != NetworkInterfaceType.Loopback
                && !tunnelAdapters.Contains(i.Name))
            .SelectMany(i => i.GetIPProperties().UnicastAddresses)
            .Select(a => (a.Address.AddressFamily == AddressFamily.InterNetworkV6 ? new IPAddress(a.Address.GetAddressBytes()) : a.Address).ToString())
            .ToList();

    public IReadOnlySet<IPFamily> BypassedFamilies(IReadOnlySet<IPFamily> families, IReadOnlySet<string> tunnelAdapters)
    {
        var bypassed = new HashSet<IPFamily>();
        if (!OperatingSystem.IsWindows() || families.Count == 0) return bypassed;
        var tunnelIndexes = new HashSet<uint>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces().Where(i => tunnelAdapters.Contains(i.Name)))
        {
            var properties = nic.GetIPProperties();
            try { tunnelIndexes.Add((uint)properties.GetIPv4Properties().Index); } catch (NetworkInformationException) { }
            try { tunnelIndexes.Add((uint)properties.GetIPv6Properties().Index); } catch (NetworkInformationException) { }
        }
        foreach (var family in families)
            foreach (var probe in Probes[family])
                if (BestInterface(IPAddress.Parse(probe)) is { } index && !tunnelIndexes.Contains(index))
                {
                    bypassed.Add(family);
                    break;
                }
        return bypassed;
    }

    public async Task<IPAddress?> ResolveAsync(string host, CancellationToken ct = default)
    {
        if (IPPrefix.TryParseAddress(host, out var literal)) return literal;
        try
        {
            var addresses = await Dns.GetHostAddressesAsync(host, ct);
            // Same preference as the service: IPv4 first.
            return addresses.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork) ?? addresses.FirstOrDefault();
        }
        catch (SocketException) { return null; }
    }

    [DllImport("iphlpapi.dll")]
    private static extern int GetBestInterfaceEx(byte[] destination, out uint index);

    private static uint? BestInterface(IPAddress address)
    {
        // SOCKADDR_IN / SOCKADDR_IN6 with Windows family values.
        var v4 = address.AddressFamily == AddressFamily.InterNetwork;
        var sockaddr = new byte[v4 ? 16 : 28];
        BitConverter.GetBytes((ushort)(v4 ? 2 : 23)).CopyTo(sockaddr, 0);
        address.GetAddressBytes().CopyTo(sockaddr, v4 ? 4 : 8);
        return GetBestInterfaceEx(sockaddr, out var index) == 0 ? index : null;
    }
}
