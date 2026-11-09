using System.Buffers.Binary;
using System.Net;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging.Abstractions;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Service.Ipc;
using WireTunnels.Service.Native;
using WireTunnels.Service.WireGuard;

#pragma warning disable CA1416 // layout checks only; nothing here calls Windows APIs

namespace WireTunnels.Service.Tests;

public class NativeLayoutTests
{
    [Fact]
    public void StructSizesMatchWindowsHeaders()
    {
        Assert.Equal(80, Unsafe.SizeOf<IpHelper.MibUnicastIpAddressRow>());
        Assert.Equal(104, Unsafe.SizeOf<IpHelper.MibIpForwardRow2>());
        Assert.Equal(168, Unsafe.SizeOf<IpHelper.MibIpInterfaceRow>());
        Assert.Equal(64, Unsafe.SizeOf<IpHelper.DnsInterfaceSettings>());
        Assert.Equal(72, Unsafe.SizeOf<Wfp.Session>());
        Assert.Equal(64, Unsafe.SizeOf<Wfp.Provider>());
        Assert.Equal(72, Unsafe.SizeOf<Wfp.SubLayer>());
        Assert.Equal(40, Unsafe.SizeOf<Wfp.Condition>());
        Assert.Equal(200, Unsafe.SizeOf<Wfp.Filter>());
    }

    [Fact]
    public void SockAddrUsesWindowsFamiliesAndNetworkPortOrder()
    {
        var buffer = new byte[SockAddr.Size];
        SockAddr.Write(buffer, IPAddress.Parse("192.0.2.1"), 51820);
        Assert.Equal(2, BinaryPrimitives.ReadUInt16LittleEndian(buffer));
        Assert.Equal([0xCA, 0x6C], buffer[2..4]);
        Assert.Equal([192, 0, 2, 1], buffer[4..8]);

        SockAddr.Write(buffer, IPAddress.Parse("2001:db8::1"), 443);
        Assert.Equal(23, BinaryPrimitives.ReadUInt16LittleEndian(buffer));
        Assert.Equal(new IPEndPoint(IPAddress.Parse("2001:db8::1"), 443), SockAddr.Read(buffer));
    }
}

public class WinTrustTests
{
    // The test host is Microsoft-signed with an embedded signature; a copied text file is not signed.
    private static string SignedByMicrosoft => Environment.ProcessPath!;

    [Fact]
    public void AcceptsOnlyTheExpectedPublisher()
    {
        if (!OperatingSystem.IsWindows()) return;
        Assert.Null(WinTrust.Verify(SignedByMicrosoft, "Microsoft Corporation"));
        Assert.Contains("not WireGuard LLC", WinTrust.Verify(SignedByMicrosoft, WireGuardNative.Publisher));
    }

    [Fact]
    public void RejectsUnsignedFiles()
    {
        if (!OperatingSystem.IsWindows()) return;
        var path = Path.Combine(Path.GetTempPath(), $"wt-unsigned-{Guid.NewGuid():N}.dll");
        File.WriteAllText(path, "not a signed binary");
        try
        {
            Assert.Contains("no valid Authenticode signature", WinTrust.Verify(path, WireGuardNative.Publisher));
        }
        finally
        {
            File.Delete(path);
        }
    }
}

public class ConfigBlobTests
{
    private static readonly (string Priv, string Pub) Local = WireGuardKey.Generate();
    private static readonly string PeerKey = WireGuardKey.Generate().PublicKey;
    private static readonly string Psk = WireGuardKey.Generate().PrivateKey;

    private static WireGuardConfig Config() => WireGuardConfig.Parse($"""
        [Interface]
        PrivateKey = {Local.Priv}
        Address = 10.0.0.2/32
        ListenPort = 51000

        [Peer]
        PublicKey = {PeerKey}
        PresharedKey = {Psk}
        AllowedIPs = 10.0.0.0/24, fd00::/64
        PersistentKeepalive = 25

        [Peer]
        PublicKey = {PeerKey}
        AllowedIPs = 0.0.0.0/0
        """);

    [Fact]
    public void LayoutMatchesWireGuardHeader()
    {
        var blob = ConfigBlob.Build(Config(), [new IPEndPoint(IPAddress.Parse("198.51.100.7"), 51820), null]);
        Assert.Equal(ConfigBlob.InterfaceSize + 2 * ConfigBlob.PeerSize + 3 * ConfigBlob.AllowedIPSize, blob.Length);

        // Interface: HAS_PRIVATE_KEY | HAS_LISTEN_PORT | REPLACE_PEERS, port, key at 6, peer count at 72.
        Assert.Equal(0b1110u, BinaryPrimitives.ReadUInt32LittleEndian(blob));
        Assert.Equal(51000, BinaryPrimitives.ReadUInt16LittleEndian(blob.AsSpan(4)));
        Assert.Equal(WireGuardKey.Decode(Local.Priv), blob[6..38]);
        Assert.Equal(2u, BinaryPrimitives.ReadUInt32LittleEndian(blob.AsSpan(72)));

        // Peer 1: HAS_PUBLIC_KEY | HAS_PRESHARED_KEY | HAS_PERSISTENT_KEEPALIVE | HAS_ENDPOINT | REPLACE_ALLOWED_IPS.
        var p = blob.AsSpan(ConfigBlob.InterfaceSize);
        Assert.Equal(0b10_1111u, BinaryPrimitives.ReadUInt32LittleEndian(p));
        Assert.Equal(WireGuardKey.Decode(Psk), p[40..72].ToArray());
        Assert.Equal(25, BinaryPrimitives.ReadUInt16LittleEndian(p[72..]));
        Assert.Equal(2u, BinaryPrimitives.ReadUInt32LittleEndian(p[128..]));

        // Allowed IP 2: fd00::/64 → AF_INET6 (23), cidr 64.
        var a = blob.AsSpan(ConfigBlob.InterfaceSize + ConfigBlob.PeerSize + ConfigBlob.AllowedIPSize);
        Assert.Equal(0xFD, a[0]);
        Assert.Equal(23, BinaryPrimitives.ReadUInt16LittleEndian(a[16..]));
        Assert.Equal(64, a[18]);

        // Peer 2 has no endpoint, PSK or keepalive.
        var p2 = blob.AsSpan(ConfigBlob.InterfaceSize + ConfigBlob.PeerSize + 2 * ConfigBlob.AllowedIPSize);
        Assert.Equal(0b10_0001u, BinaryPrimitives.ReadUInt32LittleEndian(p2));
    }

    [Fact]
    public void ReadReturnsPeersWithoutSecrets()
    {
        var blob = ConfigBlob.Build(Config(), [new IPEndPoint(IPAddress.Parse("198.51.100.7"), 51820), null]);
        BinaryPrimitives.WriteUInt64LittleEndian(blob.AsSpan(ConfigBlob.InterfaceSize + 104), 1234);  // tx
        BinaryPrimitives.WriteUInt64LittleEndian(blob.AsSpan(ConfigBlob.InterfaceSize + 112), 5678);  // rx
        var handshake = new DateTimeOffset(2026, 11, 5, 10, 0, 0, TimeSpan.Zero);
        BinaryPrimitives.WriteUInt64LittleEndian(blob.AsSpan(ConfigBlob.InterfaceSize + 120), (ulong)handshake.ToFileTime());

        var status = ConfigBlob.Read("office", blob);
        var json = JsonSerializer.Serialize(status, Protocol.Json);
        Assert.DoesNotContain(Local.Priv, json);
        Assert.DoesNotContain(Psk, json);

        Assert.Equal(51000, status.ListenPort);
        Assert.Equal(2, status.Peers.Count);
        var first = status.Peers[0];
        Assert.Equal(PeerKey, first.PublicKey);
        Assert.Equal("198.51.100.7:51820", first.Endpoint);
        Assert.Equal(["10.0.0.0/24", "fd00::/64"], first.AllowedIPs);
        Assert.Equal((1234, 5678), (first.TxBytes, first.RxBytes));
        Assert.Equal(handshake, first.LastHandshake);
        Assert.Null(status.Peers[1].Endpoint);
        Assert.Null(status.Peers[1].LastHandshake);
    }

    [Fact]
    public void TruncatedBufferIsRejected() =>
        Assert.Throws<InvalidDataException>(() => ConfigBlob.Read("x", ConfigBlob.Build(Config(), [null, null])[..100]));
}

public class RequestDispatcherTests
{
    private static readonly ClientIdentity Alice = new("S-1-5-21-1-1001", "alice", false);
    private static readonly ClientIdentity Bob = new("S-1-5-21-1-1002", "bob", false);
    private static readonly ClientIdentity Admin = new("S-1-5-21-1-500", "admin", true);

    private readonly FakeBackend _backend = new();
    private readonly NetworkFakes _net = new();
    private RequestDispatcher Dispatcher() => _net.Dispatcher(_backend);

    private static string ValidConfig(string extra = "") => $"""
        [Interface]
        PrivateKey = {WireGuardKey.Generate().PrivateKey}
        Address = 10.0.0.2/32
        {extra}
        [Peer]
        PublicKey = {WireGuardKey.Generate().PublicKey}
        AllowedIPs = 10.0.0.0/24
        """;

    private static Request Req(string op, object? args = null) =>
        new() { Id = 1, Op = op, Args = args is null ? null : JsonSerializer.SerializeToNode(args, Protocol.Json)!.AsObject() };

    private static Task<Response> Start(RequestDispatcher d, ClientIdentity who, string name, string? config = null) =>
        d.HandleAsync(Req(Ops.StartTunnel, new StartTunnelArgs { Name = name, Contents = config ?? ValidConfig() }), who, default);

    private static Task<Response> Stop(RequestDispatcher d, ClientIdentity who, string name) =>
        d.HandleAsync(Req(Ops.StopTunnel, new TunnelNameArgs { Name = name }), who, default);

    [Fact]
    public async Task UsersCannotTouchEachOthersTunnels()
    {
        var d = Dispatcher();
        Assert.True((await Start(d, Alice, "office")).Ok);
        Assert.True((await Start(d, Alice, "office")).Ok); // reconnecting your own tunnel is a no-op
        Assert.False((await Start(d, Bob, "office")).Ok);
        Assert.False((await Stop(d, Bob, "office")).Ok);
        Assert.Contains("office", _backend.Running);

        var bobStatus = await d.HandleAsync(Req(Ops.RuntimeStatusSnapshot), Bob, default);
        Assert.Empty(bobStatus.Data!.AsArray());
        var aliceStatus = await d.HandleAsync(Req(Ops.RuntimeStatusSnapshot), Alice, default);
        Assert.Single(aliceStatus.Data!.AsArray());

        Assert.True((await Stop(d, Alice, "office")).Ok);
        Assert.Empty(_backend.Running);
    }

    [Fact]
    public async Task ElevatedAdminCanStopAnyTunnel()
    {
        var d = Dispatcher();
        await Start(d, Alice, "office");
        Assert.Single((await d.HandleAsync(Req(Ops.RuntimeStatusSnapshot), Admin, default)).Data!.AsArray());
        Assert.True((await Stop(d, Admin, "office")).Ok);
        Assert.Empty(_backend.Running);
    }

    [Theory]
    [InlineData("../evil")]
    [InlineData("")]
    [InlineData("abcdefghijklmnop")]
    public async Task InvalidNamesAreRejected(string name)
    {
        var r = await Start(Dispatcher(), Alice, name);
        Assert.False(r.Ok);
        Assert.Equal("Invalid tunnel name", r.Error);
        Assert.Empty(_backend.Running);
    }

    [Fact]
    public async Task HookConfigIsRejectedByTheService()
    {
        var r = await Start(Dispatcher(), Alice, "office", ValidConfig("PostUp = powershell -c evil"));
        Assert.False(r.Ok);
        Assert.Contains("PostUp", r.Error);
        Assert.Empty(_backend.Running);
    }

    [Fact]
    public async Task MalformedRequestsFailCleanly()
    {
        var d = Dispatcher();
        Assert.False((await d.HandleAsync(new Request { Op = Ops.StartTunnel }, Alice, default)).Ok);
        Assert.False((await d.HandleAsync(new Request { Op = Ops.StartTunnel, Args = new JsonObject { ["name"] = 5 } }, Alice, default)).Ok);
        Assert.Equal("Unknown operation: nope", (await d.HandleAsync(new Request { Op = "nope" }, Alice, default)).Error);
        Assert.Equal(Protocol.Revision, (await d.HandleAsync(Req(Ops.ProtocolRevision), Alice, default)).Data!.GetValue<string>());
    }
}

public class ProtocolFramingTests
{
    [Fact]
    public async Task RoundTripsAndRejectsOversizedFrames()
    {
        var stream = new MemoryStream();
        await Protocol.WriteAsync(stream, new Request { Id = 7, Op = Ops.StopTunnel });
        stream.Position = 0;
        Assert.Equal(7, (await Protocol.ReadAsync<Request>(stream))!.Id);
        Assert.Null(await Protocol.ReadAsync<Request>(stream)); // clean end of stream

        var huge = new MemoryStream();
        huge.Write(BitConverter.GetBytes(Protocol.MaxMessageBytes + 1));
        huge.Position = 0;
        await Assert.ThrowsAsync<InvalidDataException>(() => Protocol.ReadAsync<Request>(huge));
    }
}
