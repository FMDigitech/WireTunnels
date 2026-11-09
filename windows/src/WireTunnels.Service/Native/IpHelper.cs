using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using WireTunnels.Core.Net;
using WireTunnels.Service.WireGuard;

namespace WireTunnels.Service.Native;

/// IP Helper (iphlpapi.dll): addresses, routes, interface metric/MTU, DNS on the tunnel adapter.
/// Rows are declared with explicit offsets for the fields used; sizes are asserted in tests.
[SupportedOSPlatform("windows")]
internal static partial class IpHelper
{
    private const string Dll = "iphlpapi.dll";
    private const int ErrorObjectAlreadyExists = 5010, ErrorNotFound = 1168, ErrorFileNotFound = 2;

    [StructLayout(LayoutKind.Explicit, Size = 80)]
    internal unsafe struct MibUnicastIpAddressRow
    {
        [FieldOffset(0)] public fixed byte Address[SockAddr.Size];
        [FieldOffset(32)] public ulong InterfaceLuid;
        [FieldOffset(60)] public byte OnLinkPrefixLength;
        [FieldOffset(64)] public int DadState;
    }

    [StructLayout(LayoutKind.Explicit, Size = 104)]
    internal unsafe struct MibIpForwardRow2
    {
        [FieldOffset(0)] public ulong InterfaceLuid;
        [FieldOffset(12)] public fixed byte DestinationPrefix[SockAddr.Size];
        [FieldOffset(40)] public byte DestinationPrefixLength;
        [FieldOffset(44)] public fixed byte NextHop[SockAddr.Size];
        [FieldOffset(84)] public uint Metric;
    }

    [StructLayout(LayoutKind.Explicit, Size = 168)]
    internal struct MibIpInterfaceRow
    {
        [FieldOffset(0)] public ushort Family;
        [FieldOffset(8)] public ulong InterfaceLuid;
        [FieldOffset(44)] public byte UseAutomaticMetric;
        [FieldOffset(156)] public byte Connected;
        [FieldOffset(144)] public uint SitePrefixLength;
        [FieldOffset(148)] public uint Metric;
        [FieldOffset(152)] public uint NlMtu;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DnsInterfaceSettings
    {
        public uint Version;
        public ulong Flags;
        public IntPtr Domain;
        public IntPtr NameServer;
        public IntPtr SearchList;
        public uint RegistrationEnabled;
        public uint RegisterAdapterName;
        public uint EnableLLMNR;
        public uint QueryAdapterName;
        public IntPtr ProfileNameServer;
    }

    [LibraryImport(Dll)] private static partial void InitializeUnicastIpAddressEntry(ref MibUnicastIpAddressRow row);
    [LibraryImport(Dll)] private static partial int CreateUnicastIpAddressEntry(in MibUnicastIpAddressRow row);
    [LibraryImport(Dll)] private static partial void InitializeIpForwardEntry(ref MibIpForwardRow2 row);
    [LibraryImport(Dll)] private static partial int CreateIpForwardEntry2(in MibIpForwardRow2 row);
    [LibraryImport(Dll)] private static partial int DeleteIpForwardEntry2(in MibIpForwardRow2 row);
    [LibraryImport(Dll)] private static partial int GetIpForwardTable2(ushort family, out IntPtr table);
    [LibraryImport(Dll)] private static partial void FreeMibTable(IntPtr table);
    [LibraryImport(Dll)] private static partial void InitializeIpInterfaceEntry(ref MibIpInterfaceRow row);
    [LibraryImport(Dll)] private static partial int GetIpInterfaceEntry(ref MibIpInterfaceRow row);
    [LibraryImport(Dll)] private static partial int SetIpInterfaceEntry(ref MibIpInterfaceRow row);
    [LibraryImport(Dll)] private static partial int ConvertInterfaceLuidToGuid(in ulong luid, out Guid guid);
    [LibraryImport(Dll)] private static partial int SetInterfaceDnsSettings(Guid iface, in DnsInterfaceSettings settings);

    private static void Check(int error, string what)
    {
        if (error != 0) throw new Win32Exception(error, what);
    }

    public static unsafe void AddAddress(ulong luid, IPPrefix address)
    {
        var row = new MibUnicastIpAddressRow();
        InitializeUnicastIpAddressEntry(ref row);
        SockAddr.Write(new Span<byte>(row.Address, SockAddr.Size), address.Address, 0);
        row.InterfaceLuid = luid;
        row.OnLinkPrefixLength = (byte)address.Length;
        row.DadState = 4; // IpDadStatePreferred: no duplicate-address detection on a point-to-point tunnel
        Check(CreateUnicastIpAddressEntry(row), $"Unable to add address {address}");
    }

    /// On-link route (no gateway) through the tunnel adapter.
    public static void AddRoute(ulong luid, IPPrefix destination) => AddRoute(luid, destination, null);

    /// A route on `luid`; a null or unspecified `nextHop` means on-link. Already present is success.
    public static void AddRoute(ulong luid, IPPrefix destination, IPAddress? nextHop)
    {
        var error = CreateIpForwardEntry2(Row(luid, destination, nextHop));
        if (error != ErrorObjectAlreadyExists) Check(error, $"Unable to add route {destination}");
    }

    /// Already gone (the interface went down, someone removed it) is success.
    public static void DeleteRoute(ulong luid, IPPrefix destination, IPAddress? nextHop)
    {
        var error = DeleteIpForwardEntry2(Row(luid, destination, nextHop));
        if (error is not (ErrorNotFound or ErrorFileNotFound)) Check(error, $"Unable to remove route {destination}");
    }

    private static unsafe MibIpForwardRow2 Row(ulong luid, IPPrefix destination, IPAddress? nextHop)
    {
        var row = new MibIpForwardRow2();
        InitializeIpForwardEntry(ref row);
        row.InterfaceLuid = luid;
        SockAddr.Write(new Span<byte>(row.DestinationPrefix, SockAddr.Size), destination.Address, 0);
        row.DestinationPrefixLength = (byte)destination.Length;
        // Unspecified next hop of the same family = on-link.
        SockAddr.Write(new Span<byte>(row.NextHop, SockAddr.Size),
            nextHop ?? (destination.IsIPv4 ? IPAddress.Any : IPAddress.IPv6Any), 0);
        row.Metric = 0;
        return row;
    }

    /// The default route of a family that wins outside our tunnels (lowest route + interface metric),
    /// i.e. the pre-VPN gateway. Null when the family has no other default route.
    public static unsafe (ulong Luid, IPAddress NextHop)? PhysicalDefaultRoute(bool ipv4, IReadOnlySet<ulong> excluded)
    {
        Check(GetIpForwardTable2(ipv4 ? SockAddr.AfInet : SockAddr.AfInet6, out var table), "Unable to read the routing table");
        try
        {
            var count = *(uint*)table;
            var rows = (MibIpForwardRow2*)((byte*)table + 8); // ULONG NumEntries, then 8-aligned rows
            (ulong Luid, IPAddress NextHop, ulong Metric)? best = null;
            for (var i = 0; i < count; i++)
            {
                var row = rows[i];
                if (row.DestinationPrefixLength != 0 || excluded.Contains(row.InterfaceLuid)) continue;
                if (SockAddr.Read(new ReadOnlySpan<byte>(row.NextHop, SockAddr.Size)) is not { } hop) continue;
                if (InterfaceMetric(row.InterfaceLuid, ipv4) is not { } interfaceMetric) continue;
                var metric = (ulong)row.Metric + interfaceMetric;
                if (best is null || metric < best.Value.Metric) best = (row.InterfaceLuid, hop.Address, metric);
            }
            return best is { } b ? (b.Luid, b.NextHop) : null;
        }
        finally { FreeMibTable(table); }
    }

    /// Null when the family is not enabled on the interface or the interface is disconnected.
    private static uint? InterfaceMetric(ulong luid, bool ipv4)
    {
        var row = new MibIpInterfaceRow();
        InitializeIpInterfaceEntry(ref row);
        row.Family = ipv4 ? SockAddr.AfInet : SockAddr.AfInet6;
        row.InterfaceLuid = luid;
        if (GetIpInterfaceEntry(ref row) != 0 || row.Connected == 0) return null;
        return row.Metric;
    }

    /// Lowest metric wins over the physical default route; MTU as in the config (wg-quick defaults to 1420).
    /// Returns false when the family is not enabled on the adapter (e.g. IPv6 disabled).
    public static bool ConfigureInterface(ulong luid, bool ipv4, uint mtu)
    {
        var row = new MibIpInterfaceRow();
        InitializeIpInterfaceEntry(ref row);
        row.Family = ipv4 ? SockAddr.AfInet : SockAddr.AfInet6;
        row.InterfaceLuid = luid;
        if (GetIpInterfaceEntry(ref row) != 0) return false;
        row.UseAutomaticMetric = 0;
        row.Metric = 0;
        row.NlMtu = mtu;
        if (ipv4) row.SitePrefixLength = 0; // SetIpInterfaceEntry rejects a non-zero value for IPv4
        Check(SetIpInterfaceEntry(ref row), "Unable to set interface metric/MTU");
        return true;
    }

    /// Per-adapter DNS (Windows 10 2004+). Search domains apply to the adapter's suffix list.
    public static void SetDns(ulong luid, IReadOnlyList<string> servers, IReadOnlyList<string> searchDomains)
    {
        Check(ConvertInterfaceLuidToGuid(luid, out var guid), "Unable to resolve adapter GUID");
        const ulong Ipv6 = 0x1, NameServer = 0x2, SearchList = 0x4;
        foreach (var v6 in new[] { false, true })
        {
            var family = servers.Where(s => s.Contains(':') == v6).ToList();
            if (family.Count == 0 && (v6 || searchDomains.Count == 0)) continue;
            var ns = Marshal.StringToHGlobalUni(string.Join(",", family));
            var search = Marshal.StringToHGlobalUni(string.Join(",", searchDomains));
            try
            {
                var settings = new DnsInterfaceSettings
                {
                    Version = 1,
                    Flags = NameServer | (v6 ? Ipv6 : SearchList),
                    NameServer = ns,
                    SearchList = search,
                };
                Check(SetInterfaceDnsSettings(guid, settings), "Unable to set tunnel DNS");
            }
            finally
            {
                Marshal.FreeHGlobal(ns);
                Marshal.FreeHGlobal(search);
            }
        }
    }
}
