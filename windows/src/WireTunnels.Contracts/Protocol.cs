using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace WireTunnels.Contracts;

/// App/CLI ↔ service contract over a local named pipe (the macOS WireguardHelperProtocol).
public static class Protocol
{
    public const string PipeName = "WireTunnels.Service";
    /// Bump on any incompatible change; client and service refuse to talk across revisions.
    public const string Revision = "1";
    public const int MaxMessageBytes = 1024 * 1024;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };

    /// 4-byte little-endian length prefix + UTF-8 JSON.
    public static async Task WriteAsync<T>(Stream stream, T message, CancellationToken ct = default)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(message, Json);
        if (body.Length > MaxMessageBytes) throw new InvalidDataException("Message too large");
        var header = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(header, body.Length);
        await stream.WriteAsync(header, ct);
        await stream.WriteAsync(body, ct);
        await stream.FlushAsync(ct);
    }

    /// Null at a clean end of stream.
    public static async Task<T?> ReadAsync<T>(Stream stream, CancellationToken ct = default) where T : class
    {
        var header = new byte[4];
        if (!await ReadExactlyOrEndAsync(stream, header, ct)) return null;
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length is <= 0 or > MaxMessageBytes) throw new InvalidDataException("Invalid message length");
        var body = new byte[length];
        if (!await ReadExactlyOrEndAsync(stream, body, ct)) throw new EndOfStreamException();
        return JsonSerializer.Deserialize<T>(body, Json) ?? throw new InvalidDataException("Empty message");
    }

    private static async Task<bool> ReadExactlyOrEndAsync(Stream stream, byte[] buffer, CancellationToken ct)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(read), ct);
            if (n == 0) return read == 0 ? false : throw new EndOfStreamException();
            read += n;
        }
        return true;
    }
}

/// Operation names; same semantics as the macOS helper protocol.
public static class Ops
{
    public const string ServiceVersion = "serviceVersion";
    public const string ProtocolRevision = "protocolRevision";
    public const string StartTunnel = "startTunnel";
    public const string StopTunnel = "stopTunnel";
    public const string RuntimeStatusSnapshot = "runtimeStatusSnapshot";
}

public sealed class Request
{
    public int Id { get; set; }
    public string Op { get; set; } = "";
    public JsonObject? Args { get; set; }
}

public sealed class Response
{
    public int Id { get; set; }
    public bool Ok { get; set; }
    public string? Error { get; set; }
    public JsonNode? Data { get; set; }
}

/// The config travels in memory to wireguard-nt; it is never written to disk by the service.
public sealed class StartTunnelArgs
{
    /// Tunnel alias (ConfigName.FileBaseName); also the adapter name.
    public string Name { get; set; } = "";
    public string Contents { get; set; } = "";
}

public sealed class TunnelNameArgs
{
    public string Name { get; set; } = "";
}

/// Runtime state of one tunnel. Never carries private or preshared keys.
public sealed class TunnelRuntimeStatus
{
    public string Name { get; set; } = "";
    public string? PublicKey { get; set; }
    public int ListenPort { get; set; }
    public List<PeerRuntimeStatus> Peers { get; set; } = [];
}

public sealed class PeerRuntimeStatus
{
    public string PublicKey { get; set; } = "";
    public string? Endpoint { get; set; }
    public DateTimeOffset? LastHandshake { get; set; }
    public long RxBytes { get; set; }
    public long TxBytes { get; set; }
    public List<string> AllowedIPs { get; set; } = [];
}
