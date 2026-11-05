using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace WireTunnels.Service.Native;

/// wireguard-nt (wireguard.dll, https://git.zx2c4.com/wireguard-nt/tree/api/wireguard.h).
/// Loaded only from the service's own directory, which only administrators can write.
/// shortcut: relies on the Program Files ACL; add a WinVerifyTrust check of wireguard.dll before release.
[SupportedOSPlatform("windows")]
internal static partial class WireGuardNative
{
    private const string Dll = "wireguard.dll";

    public enum AdapterState { Down = 0, Up = 1 }

    [LibraryImport(Dll, SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.ApplicationDirectory)]
    private static partial IntPtr WireGuardCreateAdapter(string name, string tunnelType, in Guid requestedGuid);

    [LibraryImport(Dll)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.ApplicationDirectory)]
    internal static partial void WireGuardCloseAdapter(IntPtr adapter);

    [LibraryImport(Dll, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.ApplicationDirectory)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WireGuardSetAdapterState(AdapterHandle adapter, AdapterState state);

    [LibraryImport(Dll)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.ApplicationDirectory)]
    private static partial void WireGuardGetAdapterLUID(AdapterHandle adapter, out ulong luid);

    [LibraryImport(Dll, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.ApplicationDirectory)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WireGuardSetConfiguration(AdapterHandle adapter, byte[] config, uint bytes);

    [LibraryImport(Dll, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.ApplicationDirectory)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WireGuardGetConfiguration(AdapterHandle adapter, byte[] config, ref uint bytes);

    /// Owns a wireguard-nt adapter: closing the handle removes the adapter, its addresses,
    /// routes and DNS settings. A crashed service therefore leaves no adapter behind.
    public sealed class AdapterHandle() : SafeHandleZeroOrMinusOneIsInvalid(ownsHandle: true)
    {
        protected override bool ReleaseHandle()
        {
            WireGuardCloseAdapter(handle);
            return true;
        }
    }

    public static AdapterHandle Create(string name, string tunnelType, Guid guid)
    {
        var raw = WireGuardCreateAdapter(name, tunnelType, guid);
        if (raw == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), $"Unable to create adapter {name}");
        var handle = new AdapterHandle();
        Marshal.InitHandle(handle, raw);
        return handle;
    }

    public static void SetState(AdapterHandle adapter, AdapterState state)
    {
        if (!WireGuardSetAdapterState(adapter, state)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static ulong Luid(AdapterHandle adapter)
    {
        WireGuardGetAdapterLUID(adapter, out var luid);
        return luid;
    }

    public static void SetConfiguration(AdapterHandle adapter, byte[] config)
    {
        try
        {
            if (!WireGuardSetConfiguration(adapter, config, (uint)config.Length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to configure adapter");
        }
        finally
        {
            Array.Clear(config); // holds the private key
        }
    }

    /// The configuration with the interface private key zeroed before it leaves this method.
    public static byte[] GetConfiguration(AdapterHandle adapter)
    {
        const int ErrorMoreData = 234;
        uint bytes = 4096;
        for (var attempt = 0; attempt < 8; attempt++)
        {
            var buffer = new byte[bytes];
            if (WireGuardGetConfiguration(adapter, buffer, ref bytes))
            {
                Array.Clear(buffer, 6, 32);
                return buffer[..(int)bytes];
            }
            Array.Clear(buffer);
            var error = Marshal.GetLastWin32Error();
            if (error != ErrorMoreData) throw new Win32Exception(error);
        }
        throw new Win32Exception(ErrorMoreData);
    }
}
