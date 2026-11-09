using System.ComponentModel;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using WireTunnels.Service.Network;

namespace WireTunnels.Service.Native;

/// Windows Filtering Platform (fwpuclnt.dll). Every filter belongs to the WireTunnels provider and
/// sublayer, so ours are found by provider key and nobody else's filters are ever touched.
/// Structs are x64/ARM64 layouts with explicit offsets; sizes are asserted in tests.
[SupportedOSPlatform("windows")]
internal static unsafe partial class Wfp
{
    private const string Dll = "fwpuclnt.dll";
    private const uint RpcCAuthnWinNT = 10;
    private const uint SessionFlagDynamic = 0x1, ProviderFlagPersistent = 0x1, SubLayerFlagPersistent = 0x1, FilterFlagPersistent = 0x1;
    private const uint ErrorAlreadyExists = 0x80320009, ErrorFilterNotFound = 0x80320003;
    private const uint ActionBlock = 0x1001, ActionPermit = 0x1002;
    private const uint TypeUint8 = 1, TypeUint16 = 2, TypeUint32 = 3, TypeUint64 = 4, TypeByteArray16 = 11, TypeV4AddrMask = 0x100, TypeV6AddrMask = 0x101;
    private const uint MatchEqual = 0, MatchFlagsAllSet = 6, MatchNotEqual = 10;
    /// Room for the largest by-pointer value: FWP_V6_ADDR_AND_MASK (17 bytes).
    private const int ScratchPerCondition = 24;

    /// Kill switch (persistent) and DNS guard (dynamic) filters.
    public static readonly Guid ProviderKey = new("6f2e3c58-2d7a-4d3e-9a51-7b1a0c9e4d21");
    /// Inventory protection: persistent, kept across reboots, never touched by the kill switch's resets.
    public static readonly Guid InventoryProviderKey = new("0d4b7a19-8e2f-4c61-b3a5-9f6e2c8d1a73");
    public static readonly Guid SubLayerKey = new("b4a1f0c2-5e3d-4b8a-8f6c-2d9e7a1c3b54");

    private static readonly Dictionary<WfpLayer, Guid> Layers = new()
    {
        [WfpLayer.ConnectV4] = new("c38d57d1-05a7-4c33-904f-7fbceee60e82"),
        [WfpLayer.ConnectV6] = new("4a72393b-319f-44bc-84c3-ba54dcb3b6b4"),
        [WfpLayer.RecvAcceptV4] = new("e1cd9fe7-f4b5-4273-96c0-592e487b8650"),
        [WfpLayer.RecvAcceptV6] = new("a3b42c97-9f04-4672-b87e-cee9c483257f"),
    };

    private static readonly Dictionary<WfpField, Guid> Fields = new()
    {
        [WfpField.LocalInterface] = new("4cd62a49-59c3-4969-b7f3-bda5d32890a4"),
        [WfpField.RemoteAddress] = new("b235ae9a-1d64-49b8-a44c-5ff3d9095045"),
        [WfpField.RemotePrefix] = new("b235ae9a-1d64-49b8-a44c-5ff3d9095045"),
        [WfpField.RemotePort] = new("c35a604d-d22b-4e1a-91b4-68f674ee674b"),
        [WfpField.LocalPort] = new("0c1ba1af-5765-453f-af22-a8f791ac775b"),
        [WfpField.IcmpType] = new("0c1ba1af-5765-453f-af22-a8f791ac775b"), // FWPM_CONDITION_ICMP_TYPE = IP_LOCAL_PORT
        [WfpField.Protocol] = new("3971ef2b-623e-4f9a-8cb1-6e79b806b9a7"),
        [WfpField.Flags] = new("632ce23b-5167-435c-86d7-e903684aa80c"),
    };

    [StructLayout(LayoutKind.Explicit, Size = 72)]
    internal struct Session
    {
        [FieldOffset(0)] public Guid SessionKey;
        [FieldOffset(16)] public IntPtr Name;
        [FieldOffset(24)] public IntPtr Description;
        [FieldOffset(32)] public uint Flags;
        [FieldOffset(36)] public uint TxnWaitTimeoutInMSec;
    }

    [StructLayout(LayoutKind.Explicit, Size = 64)]
    internal struct Provider
    {
        [FieldOffset(0)] public Guid ProviderKey;
        [FieldOffset(16)] public IntPtr Name;
        [FieldOffset(24)] public IntPtr Description;
        [FieldOffset(32)] public uint Flags;
    }

    [StructLayout(LayoutKind.Explicit, Size = 72)]
    internal struct SubLayer
    {
        [FieldOffset(0)] public Guid SubLayerKey;
        [FieldOffset(16)] public IntPtr Name;
        [FieldOffset(24)] public IntPtr Description;
        [FieldOffset(32)] public uint Flags;
        [FieldOffset(40)] public Guid* ProviderKey;
        [FieldOffset(64)] public ushort Weight;
    }

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    internal struct Condition
    {
        [FieldOffset(0)] public Guid FieldKey;
        [FieldOffset(16)] public uint MatchType;
        [FieldOffset(24)] public uint ValueType;
        [FieldOffset(32)] public ulong Value; // inline UINT8/16/32, or a pointer for UINT64 and byte arrays
    }

    [StructLayout(LayoutKind.Explicit, Size = 200)]
    internal struct Filter
    {
        [FieldOffset(0)] public Guid FilterKey;
        [FieldOffset(16)] public IntPtr Name;
        [FieldOffset(24)] public IntPtr Description;
        [FieldOffset(32)] public uint Flags;
        [FieldOffset(40)] public Guid* ProviderKey;
        [FieldOffset(64)] public Guid LayerKey;
        [FieldOffset(80)] public Guid SubLayerKey;
        [FieldOffset(96)] public uint WeightType;
        [FieldOffset(104)] public ulong WeightValue;
        [FieldOffset(112)] public uint NumFilterConditions;
        [FieldOffset(120)] public Condition* FilterCondition;
        [FieldOffset(128)] public uint ActionType;
        [FieldOffset(176)] public ulong FilterId;
    }

    [LibraryImport(Dll)] private static partial uint FwpmEngineOpen0(IntPtr serverName, uint authnService, IntPtr authIdentity, in Session session, out IntPtr engine);
    [LibraryImport(Dll)] private static partial uint FwpmEngineClose0(IntPtr engine);
    [LibraryImport(Dll)] private static partial uint FwpmTransactionBegin0(IntPtr engine, uint flags);
    [LibraryImport(Dll)] private static partial uint FwpmTransactionCommit0(IntPtr engine);
    [LibraryImport(Dll)] private static partial uint FwpmTransactionAbort0(IntPtr engine);
    [LibraryImport(Dll)] private static partial uint FwpmProviderAdd0(IntPtr engine, in Provider provider, IntPtr sd);
    [LibraryImport(Dll)] private static partial uint FwpmSubLayerAdd0(IntPtr engine, in SubLayer subLayer, IntPtr sd);
    [LibraryImport(Dll)] private static partial uint FwpmFilterAdd0(IntPtr engine, in Filter filter, IntPtr sd, out ulong id);
    [LibraryImport(Dll)] private static partial uint FwpmFilterDeleteById0(IntPtr engine, ulong id);
    [LibraryImport(Dll)] private static partial uint FwpmFilterCreateEnumHandle0(IntPtr engine, IntPtr template, out IntPtr handle);
    [LibraryImport(Dll)] private static partial uint FwpmFilterEnum0(IntPtr engine, IntPtr handle, uint requested, out Filter** entries, out uint returned);
    [LibraryImport(Dll)] private static partial uint FwpmFilterDestroyEnumHandle0(IntPtr engine, IntPtr handle);
    [LibraryImport(Dll)] private static partial void FwpmFreeMemory0(ref IntPtr p);

    private static void Check(uint error, string what)
    {
        if (error != 0) throw new Win32Exception((int)error, $"{what} (0x{error:X8})");
    }

    /// A dynamic engine's objects disappear when its handle closes or the process dies.
    public static IntPtr Open(bool dynamic)
    {
        var name = Marshal.StringToHGlobalUni("WireTunnels");
        try
        {
            var session = new Session { Name = name, Flags = dynamic ? SessionFlagDynamic : 0, TxnWaitTimeoutInMSec = 5000 };
            Check(FwpmEngineOpen0(IntPtr.Zero, RpcCAuthnWinNT, IntPtr.Zero, session, out var engine), "Unable to open the Windows Filtering Platform");
            return engine;
        }
        finally { Marshal.FreeHGlobal(name); }
    }

    public static void Close(IntPtr engine) => FwpmEngineClose0(engine);

    /// Persistent provider and sublayer, created once; the highest sublayer weight so our verdict is evaluated.
    public static void EnsureProviderAndSubLayer(IntPtr engine)
    {
        var name = Marshal.StringToHGlobalUni("WireTunnels");
        try
        {
            foreach (var providerKey in new[] { ProviderKey, InventoryProviderKey })
            {
                var provider = new Provider { ProviderKey = providerKey, Name = name, Flags = ProviderFlagPersistent };
                var added = FwpmProviderAdd0(engine, provider, IntPtr.Zero);
                if (added != ErrorAlreadyExists) Check(added, "Unable to register the WireTunnels firewall provider");
            }
            uint error;
            var key = ProviderKey;
            var subLayer = new SubLayer { SubLayerKey = SubLayerKey, Name = name, Flags = SubLayerFlagPersistent, ProviderKey = &key, Weight = ushort.MaxValue };
            error = FwpmSubLayerAdd0(engine, subLayer, IntPtr.Zero);
            if (error != ErrorAlreadyExists) Check(error, "Unable to register the WireTunnels firewall sublayer");
        }
        finally { Marshal.FreeHGlobal(name); }
    }

    /// Runs `body` in one WFP transaction: either every change applies or none does.
    public static void Transaction(IntPtr engine, Action body)
    {
        Check(FwpmTransactionBegin0(engine, 0), "Unable to start a firewall transaction");
        try
        {
            body();
            Check(FwpmTransactionCommit0(engine), "Unable to commit the firewall rules");
        }
        catch
        {
            FwpmTransactionAbort0(engine);
            throw;
        }
    }

    /// Ids of our filters of one set: `provider` and `persistent` pick it (see the provider keys).
    public static List<ulong> OurFilters(IntPtr engine, bool persistent) => OurFilters(engine, ProviderKey, persistent);

    public static List<ulong> OurFilters(IntPtr engine, Guid provider, bool persistent)
    {
        var ids = new List<ulong>();
        Check(FwpmFilterCreateEnumHandle0(engine, IntPtr.Zero, out var handle), "Unable to list firewall filters");
        try
        {
            while (true)
            {
                Check(FwpmFilterEnum0(engine, handle, 256, out var entries, out var count), "Unable to list firewall filters");
                try
                {
                    for (var i = 0; i < count; i++)
                    {
                        var filter = entries[i];
                        if (filter->ProviderKey != null && *filter->ProviderKey == provider
                            && ((filter->Flags & FilterFlagPersistent) != 0) == persistent)
                            ids.Add(filter->FilterId);
                    }
                }
                finally
                {
                    var p = (IntPtr)entries;
                    if (p != IntPtr.Zero) FwpmFreeMemory0(ref p);
                }
                if (count < 256) return ids;
            }
        }
        finally { FwpmFilterDestroyEnumHandle0(engine, handle); }
    }

    public static void Delete(IntPtr engine, ulong id)
    {
        var error = FwpmFilterDeleteById0(engine, id);
        if (error != ErrorFilterNotFound) Check(error, "Unable to remove a firewall filter");
    }

    public static void Add(IntPtr engine, WfpFilter spec, bool persistent) => Add(engine, spec, ProviderKey, persistent);

    public static void Add(IntPtr engine, WfpFilter spec, Guid provider, bool persistent)
    {
        // Condition values that WFP takes by pointer live in this block until the call returns.
        var extra = spec.Conditions.Count * ScratchPerCondition;
        var block = (byte*)NativeMemory.AllocZeroed((nuint)(spec.Conditions.Count * sizeof(Condition) + extra + 1));
        var name = Marshal.StringToHGlobalUni("WireTunnels: " + spec.Name);
        try
        {
            var conditions = (Condition*)block;
            var data = block + spec.Conditions.Count * sizeof(Condition);
            for (var i = 0; i < spec.Conditions.Count; i++)
                conditions[i] = Encode(spec.Conditions[i], data + i * ScratchPerCondition);
            var key = provider;
            var filter = new Filter
            {
                FilterKey = Guid.NewGuid(),
                Name = name,
                Flags = persistent ? FilterFlagPersistent : 0,
                ProviderKey = &key,
                LayerKey = Layers[spec.Layer],
                SubLayerKey = SubLayerKey,
                WeightType = TypeUint8,
                WeightValue = spec.Weight,
                NumFilterConditions = (uint)spec.Conditions.Count,
                FilterCondition = spec.Conditions.Count > 0 ? conditions : null,
                ActionType = spec.Permit ? ActionPermit : ActionBlock,
            };
            Check(FwpmFilterAdd0(engine, filter, IntPtr.Zero, out _), $"Unable to add the firewall filter \"{spec.Name}\"");
        }
        finally
        {
            Marshal.FreeHGlobal(name);
            NativeMemory.Free(block);
        }
    }

    private static Condition Encode(WfpCondition c, byte* scratch)
    {
        var condition = new Condition { FieldKey = Fields[c.Field], MatchType = c.NotEqual ? MatchNotEqual : MatchEqual };
        switch (c.Field)
        {
            case WfpField.RemotePrefix when c.Prefix!.Value.IsIPv4:
                // FWP_V4_ADDR_AND_MASK: address and mask, both UINT32 in host byte order.
                var bytes = c.Prefix.Value.Bytes;
                ((uint*)scratch)[0] = (uint)(bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]);
                ((uint*)scratch)[1] = c.Prefix.Value.Length == 0 ? 0 : uint.MaxValue << (32 - c.Prefix.Value.Length);
                (condition.ValueType, condition.Value) = (TypeV4AddrMask, (ulong)scratch);
                break;
            case WfpField.RemotePrefix:
                // FWP_V6_ADDR_AND_MASK: 16 address bytes, then the prefix length.
                c.Prefix!.Value.Bytes.CopyTo(new Span<byte>(scratch, 16));
                scratch[16] = (byte)c.Prefix.Value.Length;
                (condition.ValueType, condition.Value) = (TypeV6AddrMask, (ulong)scratch);
                break;
            case WfpField.LocalInterface:
                *(ulong*)scratch = c.Number;
                (condition.ValueType, condition.Value) = (TypeUint64, (ulong)scratch);
                break;
            case WfpField.Protocol:
                (condition.ValueType, condition.Value) = (TypeUint8, c.Number);
                break;
            case WfpField.Flags:
                (condition.MatchType, condition.ValueType, condition.Value) = (MatchFlagsAllSet, TypeUint32, c.Number);
                break;
            case WfpField.RemoteAddress when c.Address!.AddressFamily == AddressFamily.InterNetwork:
                // FWP_UINT32 in host byte order.
                (condition.ValueType, condition.Value) = (TypeUint32, (ulong)(uint)IPAddress.NetworkToHostOrder(BitConverter.ToInt32(c.Address.GetAddressBytes())));
                break;
            case WfpField.RemoteAddress:
                c.Address.GetAddressBytes().CopyTo(new Span<byte>(scratch, 16));
                (condition.ValueType, condition.Value) = (TypeByteArray16, (ulong)scratch);
                break;
            default: // ports and ICMP type
                (condition.ValueType, condition.Value) = (TypeUint16, c.Number);
                break;
        }
        return condition;
    }
}
