using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32;

namespace WireTunnels.Client;

/// The physical network as On-Demand rules and recovery see it (macOS PhysicalNetworkSnapshot).
public sealed record PhysicalNetwork(
    bool IsOnEthernet,
    IReadOnlyList<string> EthernetAddresses,
    bool IsOnWiFi,
    /// Null when not on Wi-Fi or when Windows withholds it.
    string? Ssid,
    /// Windows withholds the SSID: location access is off for desktop apps (Windows 11 24H2 and later).
    bool WiFiNameDenied,
    IReadOnlyList<string> Gateways)
{
    public static readonly PhysicalNetwork None = new(false, [], false, null, false, []);

    /// What a rule can match on changed (links, SSID, Ethernet addresses).
    public bool RulesInputsDiffer(PhysicalNetwork other) =>
        IsOnEthernet != other.IsOnEthernet || IsOnWiFi != other.IsOnWiFi || Ssid != other.Ssid
        || !EthernetAddresses.SequenceEqual(other.EthernetAddresses);
}

/// Network and power notifications plus a snapshot reader (macOS NetworkMonitorService); faked in tests.
/// Events fire on any thread; TunnelManager marshals them to its own.
public interface INetworkMonitor
{
    event Action? Changed;
    event Action? Woke;
    /// Null when the state cannot be read (the previous snapshot is kept).
    PhysicalNetwork? Read(IReadOnlySet<string> tunnelAdapters);
}

[SupportedOSPlatform("windows")]
public sealed partial class SystemNetworkMonitor : INetworkMonitor, IDisposable
{
    public event Action? Changed;
    public event Action? Woke;

    public SystemNetworkMonitor()
    {
        NetworkChange.NetworkAddressChanged += OnChanged;
        NetworkChange.NetworkAvailabilityChanged += OnAvailability;
        SystemEvents.PowerModeChanged += OnPower;
    }

    private void OnChanged(object? sender, EventArgs e) => Changed?.Invoke();
    private void OnAvailability(object? sender, NetworkAvailabilityEventArgs e) => Changed?.Invoke();
    private void OnPower(object? sender, PowerModeChangedEventArgs e) { if (e.Mode == PowerModes.Resume) Woke?.Invoke(); }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnAvailability;
        SystemEvents.PowerModeChanged -= OnPower;
    }

    public PhysicalNetwork? Read(IReadOnlySet<string> tunnelAdapters)
    {
        try
        {
            var up = NetworkInterface.GetAllNetworkInterfaces()
                .Where(i => i.OperationalStatus == OperationalStatus.Up && !tunnelAdapters.Contains(i.Name)
                    && i.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet
                        or NetworkInterfaceType.FastEthernetT or NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.Ethernet3Megabit
                        or NetworkInterfaceType.Wireless80211)
                .Select(i => (Nic: i, Props: i.GetIPProperties()))
                // A link without a routable address (e.g. a cable to nothing, APIPA) is not "on" that network.
                .Where(x => x.Props.UnicastAddresses.Any(a => !IsLinkLocal(a.Address)))
                .ToList();
            var ethernet = up.Where(x => x.Nic.NetworkInterfaceType != NetworkInterfaceType.Wireless80211).ToList();
            var wifi = up.Where(x => x.Nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211).ToList();
            var (ssid, denied) = wifi.Count > 0 ? CurrentSsid() : (null, false);
            return new PhysicalNetwork(
                ethernet.Count > 0,
                ethernet.SelectMany(x => x.Props.UnicastAddresses).Where(a => !IsLinkLocal(a.Address))
                    .Select(a => a.Address.ToString()).Order(StringComparer.Ordinal).ToList(),
                wifi.Count > 0, ssid, denied,
                up.SelectMany(x => x.Props.GatewayAddresses).Select(g => g.Address.ToString()).Where(g => g is not "0.0.0.0" and not "::")
                    .Distinct().Order(StringComparer.Ordinal).ToList());
        }
        catch (NetworkInformationException) { return null; }
    }

    private static bool IsLinkLocal(System.Net.IPAddress a) =>
        a.IsIPv6LinkLocal || (a.AddressFamily == AddressFamily.InterNetwork && a.GetAddressBytes() is [169, 254, ..]);

    // MARK: Wi-Fi name (wlanapi)

    private const int WlanIntfOpcodeCurrentConnection = 7, AccessDenied = 5, Connected = 1;
    private const int InterfaceInfoSize = 532, SsidLengthOffset = 520;

    /// The SSID of the first connected Wi-Fi interface. Since Windows 11 24H2 WlanQueryInterface returns
    /// ERROR_ACCESS_DENIED unless "Let desktop apps access your location" is on.
    private static (string? Ssid, bool Denied) CurrentSsid()
    {
        if (WlanOpenHandle(2, IntPtr.Zero, out _, out var client) != 0) return (null, false);
        var list = IntPtr.Zero;
        try
        {
            if (WlanEnumInterfaces(client, IntPtr.Zero, out list) != 0) return (null, false);
            var count = Marshal.ReadInt32(list);
            var denied = false;
            for (var i = 0; i < count; i++)
            {
                var item = list + 8 + i * InterfaceInfoSize;
                if (Marshal.ReadInt32(item + 528) != Connected) continue;
                var guid = Marshal.PtrToStructure<Guid>(item);
                var result = WlanQueryInterface(client, ref guid, WlanIntfOpcodeCurrentConnection, IntPtr.Zero, out _, out var data, out _);
                if (result == AccessDenied) { denied = true; continue; }
                if (result != 0) continue;
                try
                {
                    var length = Math.Clamp(Marshal.ReadInt32(data + SsidLengthOffset), 0, 32);
                    var bytes = new byte[length];
                    Marshal.Copy(data + SsidLengthOffset + 4, bytes, 0, length);
                    return (Encoding.UTF8.GetString(bytes), false);
                }
                finally { WlanFreeMemory(data); }
            }
            return (null, denied);
        }
        finally
        {
            if (list != IntPtr.Zero) WlanFreeMemory(list);
            WlanCloseHandle(client, IntPtr.Zero);
        }
    }

    [LibraryImport("wlanapi.dll")]
    private static partial int WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr client);

    [LibraryImport("wlanapi.dll")]
    private static partial int WlanCloseHandle(IntPtr client, IntPtr reserved);

    [LibraryImport("wlanapi.dll")]
    private static partial int WlanEnumInterfaces(IntPtr client, IntPtr reserved, out IntPtr list);

    [LibraryImport("wlanapi.dll")]
    private static partial int WlanQueryInterface(IntPtr client, ref Guid iface, int opcode, IntPtr reserved, out int size, out IntPtr data, out int valueType);

    [LibraryImport("wlanapi.dll")]
    private static partial void WlanFreeMemory(IntPtr memory);
}
