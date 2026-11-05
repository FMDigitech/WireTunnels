using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;

namespace WireTunnels.Service.WireGuard;

/// Builds and reads the buffer of WireGuardSetConfiguration / WireGuardGetConfiguration (wireguard.h):
/// WIREGUARD_INTERFACE, then per peer a WIREGUARD_PEER followed by its WIREGUARD_ALLOWED_IP entries.
/// All three structs are ALIGNED(8); offsets below match wireguard.h on x64 and ARM64.
internal static class ConfigBlob
{
    public const int InterfaceSize = 80;
    public const int PeerSize = 136;
    public const int AllowedIPSize = 24;

    // WIREGUARD_INTERFACE_FLAG
    private const uint IfHasPublicKey = 1 << 0, IfHasPrivateKey = 1 << 1, IfHasListenPort = 1 << 2, IfReplacePeers = 1 << 3;
    // WIREGUARD_PEER_FLAG
    private const uint PeerHasPublicKey = 1 << 0, PeerHasPresharedKey = 1 << 1, PeerHasKeepalive = 1 << 2,
        PeerHasEndpoint = 1 << 3, PeerReplaceAllowedIPs = 1 << 5;

    /// `endpoints[i]` is peer i's endpoint, already resolved (the driver takes numeric addresses only).
    public static byte[] Build(WireGuardConfig config, IReadOnlyList<IPEndPoint?> endpoints)
    {
        if (endpoints.Count != config.Peers.Count) throw new ArgumentException("One endpoint slot per peer");
        var allowed = config.Peers.Select(p => p.AllowedIPs.Select(Core.Net.IPPrefix.Parse).ToList()).ToList();
        var buffer = new byte[InterfaceSize + config.Peers.Count * PeerSize + allowed.Sum(a => a.Count) * AllowedIPSize];
        var span = buffer.AsSpan();

        var flags = IfHasPrivateKey | IfReplacePeers | (config.ListenPort is not null ? IfHasListenPort : 0);
        BinaryPrimitives.WriteUInt32LittleEndian(span[0..], flags);
        BinaryPrimitives.WriteUInt16LittleEndian(span[4..], (ushort)(config.ListenPort ?? 0));
        Key(config.PrivateKey!).CopyTo(span[6..]);
        BinaryPrimitives.WriteUInt32LittleEndian(span[72..], (uint)config.Peers.Count);

        var offset = InterfaceSize;
        for (var i = 0; i < config.Peers.Count; i++)
        {
            var peer = config.Peers[i];
            var p = span.Slice(offset, PeerSize);
            var peerFlags = PeerHasPublicKey | PeerReplaceAllowedIPs
                | (peer.PresharedKey is not null ? PeerHasPresharedKey : 0)
                | (peer.PersistentKeepalive is not null ? PeerHasKeepalive : 0)
                | (endpoints[i] is not null ? PeerHasEndpoint : 0);
            BinaryPrimitives.WriteUInt32LittleEndian(p[0..], peerFlags);
            Key(peer.PublicKey!).CopyTo(p[8..]);
            if (peer.PresharedKey is { } psk) Key(psk).CopyTo(p[40..]);
            BinaryPrimitives.WriteUInt16LittleEndian(p[72..], (ushort)(peer.PersistentKeepalive ?? 0));
            if (endpoints[i] is { } ep) SockAddr.Write(p.Slice(76, SockAddr.Size), ep.Address, ep.Port);
            BinaryPrimitives.WriteUInt32LittleEndian(p[128..], (uint)allowed[i].Count);
            offset += PeerSize;

            foreach (var prefix in allowed[i])
            {
                var a = span.Slice(offset, AllowedIPSize);
                prefix.Bytes.CopyTo(a);
                BinaryPrimitives.WriteUInt16LittleEndian(a[16..], prefix.IsIPv4 ? SockAddr.AfInet : SockAddr.AfInet6);
                a[18] = (byte)prefix.Length;
                offset += AllowedIPSize;
            }
        }
        return buffer;
    }

    /// Runtime status without any key material except public keys.
    public static TunnelRuntimeStatus Read(string name, ReadOnlySpan<byte> buffer)
    {
        if (buffer.Length < InterfaceSize) throw new InvalidDataException("Short interface buffer");
        var flags = BinaryPrimitives.ReadUInt32LittleEndian(buffer);
        var status = new TunnelRuntimeStatus
        {
            Name = name,
            ListenPort = BinaryPrimitives.ReadUInt16LittleEndian(buffer[4..]),
            PublicKey = (flags & IfHasPublicKey) != 0 ? Convert.ToBase64String(buffer.Slice(38, 32)) : null,
        };
        var peerCount = BinaryPrimitives.ReadUInt32LittleEndian(buffer[72..]);
        var offset = InterfaceSize;
        for (var i = 0; i < peerCount; i++)
        {
            if (buffer.Length < offset + PeerSize) throw new InvalidDataException("Short peer buffer");
            var p = buffer.Slice(offset, PeerSize);
            var peerFlags = BinaryPrimitives.ReadUInt32LittleEndian(p);
            var handshake = BinaryPrimitives.ReadUInt64LittleEndian(p[120..]);
            var ep = (peerFlags & PeerHasEndpoint) != 0 ? SockAddr.Read(p.Slice(76, SockAddr.Size)) : null;
            var peer = new PeerRuntimeStatus
            {
                PublicKey = Convert.ToBase64String(p.Slice(8, 32)),
                Endpoint = ep?.ToString(),
                TxBytes = (long)BinaryPrimitives.ReadUInt64LittleEndian(p[104..]),
                RxBytes = (long)BinaryPrimitives.ReadUInt64LittleEndian(p[112..]),
                // FILETIME (100 ns since 1601); 0 = never.
                LastHandshake = handshake == 0 ? null : DateTimeOffset.FromFileTime((long)handshake),
            };
            var allowedCount = BinaryPrimitives.ReadUInt32LittleEndian(p[128..]);
            offset += PeerSize;
            for (var j = 0; j < allowedCount; j++)
            {
                if (buffer.Length < offset + AllowedIPSize) throw new InvalidDataException("Short allowed-IP buffer");
                var a = buffer.Slice(offset, AllowedIPSize);
                var v4 = BinaryPrimitives.ReadUInt16LittleEndian(a[16..]) == SockAddr.AfInet;
                peer.AllowedIPs.Add($"{new IPAddress(a[..(v4 ? 4 : 16)])}/{a[18]}");
                offset += AllowedIPSize;
            }
            status.Peers.Add(peer);
        }
        return status;
    }

    private static byte[] Key(string base64) =>
        WireGuardKey.Decode(base64) ?? throw new InvalidDataException("Invalid key");
}

/// SOCKADDR_INET (28 bytes) with Windows address-family values.
internal static class SockAddr
{
    public const int Size = 28;
    public const ushort AfInet = 2, AfInet6 = 23;

    public static void Write(Span<byte> dest, IPAddress address, int port)
    {
        dest.Clear();
        var v4 = address.AddressFamily == AddressFamily.InterNetwork;
        BinaryPrimitives.WriteUInt16LittleEndian(dest, v4 ? AfInet : AfInet6);
        BinaryPrimitives.WriteUInt16BigEndian(dest[2..], (ushort)port);
        if (v4) address.GetAddressBytes().CopyTo(dest[4..]);
        else
        {
            address.GetAddressBytes().CopyTo(dest[8..]);
            BinaryPrimitives.WriteUInt32LittleEndian(dest[24..], (uint)address.ScopeId);
        }
    }

    public static IPEndPoint? Read(ReadOnlySpan<byte> src)
    {
        var port = BinaryPrimitives.ReadUInt16BigEndian(src[2..]);
        return BinaryPrimitives.ReadUInt16LittleEndian(src) switch
        {
            AfInet => new IPEndPoint(new IPAddress(src.Slice(4, 4)), port),
            AfInet6 => new IPEndPoint(new IPAddress(src.Slice(8, 16), BinaryPrimitives.ReadUInt32LittleEndian(src[24..])), port),
            _ => null,
        };
    }
}
