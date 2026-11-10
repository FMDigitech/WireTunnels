using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using WireTunnels.Core.Models;

namespace WireTunnels.Contracts;

/// App/CLI ↔ service contract over a local named pipe (the macOS WireguardHelperProtocol).
public static class Protocol
{
    public const string PipeName = "WireTunnels.Service";
    /// Bump on any incompatible change; client and service refuse to talk across revisions.
    public const string Revision = "4";
    /// Room for an inventory of 100,000 prefixes (the macOS helper accepts 8 MiB of inventory too).
    public const int MaxMessageBytes = 16 * 1024 * 1024;

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
    public const string SyncKillSwitch = "syncKillSwitch";
    public const string SyncSplitDns = "syncSplitDNS";
    public const string SyncRoutes = "syncRoutes";
    public const string UpdateInventoryRouting = "updateInventoryRouting";
    // Shared (managed) tunnels: configs live in the service and never reach a non-admin client.
    public const string ListManaged = "listManagedTunnels";
    public const string StartManaged = "startManagedTunnel";
    public const string GetSystemSettings = "getSystemSettings";
    // Elevated administrators only (ClientIdentity.IsElevatedAdmin).
    public const string ReadManaged = "readManagedConfig";
    public const string InstallManaged = "installManagedTunnel";
    public const string UpdateManaged = "updateManagedTunnel";
    public const string DeleteManaged = "deleteManagedTunnel";
    public const string ListManagedUsers = "listManagedTunnelUsers";
    public const string SetSystemSettings = "setSystemSettings";
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
    /// Leave the adapter's DNS alone: split DNS (NRPT) or a multi-hop hop leg.
    public bool SuppressDns { get; set; }
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

/// Network policy ops are declarative: each call sends the caller's complete desired state,
/// and the service replaces what that user had before (other users' state is never touched).
public sealed class KillSwitchEntry
{
    /// Tunnel alias; the tunnel may be down (that is when the kill switch blocks).
    public string Name { get; set; } = "";
    /// Numeric peer endpoint, so the handshake can get out while everything else is blocked.
    public string EndpointHost { get; set; } = "";
    public int EndpointPort { get; set; }
}

public sealed class SyncKillSwitchArgs
{
    public List<KillSwitchEntry> Entries { get; set; } = [];
}

public sealed class SplitDnsEntry
{
    public string OwnerId { get; set; } = "";
    public List<string> Domains { get; set; } = [];
    public List<string> Servers { get; set; } = [];
}

public sealed class SyncSplitDnsArgs
{
    public List<SplitDnsEntry> Entries { get; set; } = [];
}

/// A route the service adds for the caller: through the physical default gateway (Tunnel = null,
/// split-tunnel exclusions and a multi-hop hop endpoint) or on-link through one of the caller's tunnels.
public sealed record RouteEntry
{
    public string Cidr { get; init; } = "";
    public string? Tunnel { get; init; }
}

public sealed class SyncRoutesArgs
{
    /// A tunnel id (exclusions) or a hop-chain id (its host routes).
    public Guid OwnerId { get; set; }
    public List<RouteEntry> Entries { get; set; } = [];
}

public sealed class ManagedIdArgs
{
    public Guid Id { get; set; }
}

public sealed class InstallManagedArgs
{
    public string Name { get; set; } = "";
    public string Contents { get; set; } = "";
}

/// Port of updateManagedTunnel: a null Contents keeps the stored config.
public sealed class UpdateManagedArgs
{
    public Guid Id { get; set; }
    public string Name { get; set; } = "";
    public string? Contents { get; set; }
    public ManagedTunnelPolicy Policy { get; set; } = new();
    public AutoConnectRule AutoConnectRule { get; set; } = new();
}

public enum InventoryAction { Protect, Apply, Remove }

/// Port of InventoryRoutingRequest. Protect blocks the tunnel's destinations everywhere; apply (tunnel
/// connected) lets them through its adapter only and adds the discovered ones to its AllowedIPs and routes;
/// remove drops the policy. The app runs the inventory command; the service never does.
public sealed class InventoryRoutingRequest
{
    public InventoryAction Action { get; set; }
    public Guid OwnerId { get; set; }
    /// Changes on every connect and protect: an apply from an older connection is rejected.
    public Guid Generation { get; set; }
    /// Tunnel alias.
    public string Name { get; set; } = "";
    public string LocalPublicKey { get; set; } = "";
    public string PeerPublicKey { get; set; } = "";
    /// The config's AllowedIPs.
    public List<string> StaticPrefixes { get; set; } = [];
    /// The inventory command's last output.
    public List<string> DiscoveredPrefixes { get; set; } = [];
    /// Reuse what the service has (it outlives app restarts) instead of DiscoveredPrefixes.
    public bool UseCachedInventory { get; set; }
    /// The peer endpoint, numeric: reachable over UDP while the destinations are blocked, so the tunnel can connect.
    public string? EndpointHost { get; set; }
    public int EndpointPort { get; set; }

    public static InventoryRoutingRequest Removal(Guid ownerId) => new() { Action = InventoryAction.Remove, OwnerId = ownerId };
}
