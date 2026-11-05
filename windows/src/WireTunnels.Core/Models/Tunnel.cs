using System.Text.Json.Serialization;

namespace WireTunnels.Core.Models;

/// Same JSON shape as the macOS `tunnels.json` (camelCase keys, missing keys take the defaults below),
/// so metadata can be imported from WireTunnels for macOS.
public enum TunnelScope { Personal, Managed }

public sealed class ManagedTunnelPolicy
{
    public bool UsersCanConnect { get; set; } = true;
    public bool UsersCanDisconnect { get; set; } = true;
    public bool KillSwitchEnabled { get; set; }
    public List<string> SplitDNSDomains { get; set; } = [];
}

/// Device-wide settings set by an administrator, stored by the service.
public sealed class SystemSettings
{
    public bool RequireAdminToDisableLaunchAtLogin { get; set; }
}

public sealed class ManagedTunnelUserSession
{
    /// Windows user SID (the macOS uid).
    public string Sid { get; set; } = "";
    public string Username { get; set; } = "";
    public DateTimeOffset ConnectedAt { get; set; }
}

public sealed class InventoryCommand
{
    public string Executable { get; set; } = "";
    public List<string> Arguments { get; set; } = [];
}

public sealed class Tunnel
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string ConfigPath { get; set; } = "";
    public string? RuntimeConfigPath { get; set; }
    /// wireguard-nt adapter name (the config alias, see ConfigName.FileBaseName).
    public string? InterfaceName { get; set; }
    public bool IsActive { get; set; }
    public bool IsFavorite { get; set; }
    public bool Autostart { get; set; }
    public AutoConnectRule AutoConnectRule { get; set; } = new();
    public bool KillSwitchEnabled { get; set; }
    public bool IpFamilyLeakWarningAcknowledged { get; set; }
    public List<string>? Address { get; set; }
    public List<string> AllowedIPs { get; set; } = [];
    public List<string> ExcludedRoutes { get; set; } = [];
    public List<string> Dns { get; set; } = [];
    public List<string> SplitDNSDomains { get; set; } = [];
    public string? Endpoint { get; set; }
    public string? PublicKey { get; set; }
    public string? LocalPublicKey { get; set; }
    public string? SpeedTestURL { get; set; }
    public InventoryCommand? InventoryCommand { get; set; }
    public List<string> InventoryAllowedIPs { get; set; } = [];
    public DateTimeOffset? InventoryUpdatedAt { get; set; }
    public DateTimeOffset? LastHandshake { get; set; }
    public long RxBytes { get; set; }
    public long TxBytes { get; set; }
    public DateTimeOffset? ConnectedAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    public TunnelScope Scope { get; set; } = TunnelScope.Personal;
    public ManagedTunnelPolicy? ManagedPolicy { get; set; }

    /// Personal tunnels use their own list; managed tunnels the admin-set policy.
    [JsonIgnore]
    public IReadOnlyList<string> EffectiveSplitDNSDomains =>
        Scope == TunnelScope.Managed ? ManagedPolicy?.SplitDNSDomains ?? [] : SplitDNSDomains;

    [JsonIgnore]
    public bool IsKillSwitchEnabled =>
        Scope == TunnelScope.Managed ? ManagedPolicy?.KillSwitchEnabled ?? false : KillSwitchEnabled;
}

/// Client-side multi-hop: the exit tunnel's packets are routed through the hop tunnel.
public sealed class HopChain
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid HopTunnelID { get; set; }
    public Guid ExitTunnelID { get; set; }
    public bool IsEnabled { get; set; } = true;
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}
