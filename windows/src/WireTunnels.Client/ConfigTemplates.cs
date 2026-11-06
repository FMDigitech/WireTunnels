namespace WireTunnels.Client;

/// Port of WireGuardTemplate in TemplatePickerView.swift.
public sealed record ConfigTemplate(string Name, string Description, string Glyph, string Content)
{
    public static readonly IReadOnlyList<ConfigTemplate> All =
    [
        new("Empty", "Blank config with all required sections.", "", """
            [Interface]
            PrivateKey =
            Address =
            DNS =

            [Peer]
            PublicKey =
            Endpoint =
            AllowedIPs =
            PersistentKeepalive = 25
            """),
        new("Split Tunnel", "Routes only specific subnets through the VPN.", "", """
            [Interface]
            PrivateKey = <PRIVATE_KEY>
            Address = 10.8.0.2/24
            DNS = 10.8.0.1

            [Peer]
            PublicKey = <SERVER_PUBLIC_KEY>
            Endpoint = vpn.example.com:51820
            AllowedIPs = 10.8.0.0/24, 192.168.0.0/24
            PersistentKeepalive = 25
            """),
        new("Full Tunnel", "Routes all traffic (0.0.0.0/0) through the VPN.", "", """
            [Interface]
            PrivateKey = <PRIVATE_KEY>
            Address = 10.8.0.2/24
            DNS = 1.1.1.1

            [Peer]
            PublicKey = <SERVER_PUBLIC_KEY>
            Endpoint = vpn.example.com:51820
            AllowedIPs = 0.0.0.0/0, ::/0
            PersistentKeepalive = 25
            """),
    ];
}

/// The fields of the basic form (NewTunnelView / ConfigEditorSheetView).
public sealed class BasicConfigForm
{
    public string PrivateKey { get; set; } = "";
    public string Address { get; set; } = "";
    public string Dns { get; set; } = "";
    public string SearchDomains { get; set; } = "";
    public string PeerPublicKey { get; set; } = "";
    public string PresharedKey { get; set; } = "";
    public string Endpoint { get; set; } = "";
    public string AllowedIPs { get; set; } = "";
    public string PersistentKeepalive { get; set; } = "";

    public IReadOnlyList<string> InvalidSearchDomains => Core.Config.WireGuardDns.Compose(Dns, SearchDomains).InvalidDomains;

    public bool CanSave => PrivateKey.Trim().Length > 0 && Address.Trim().Length > 0 && InvalidSearchDomains.Count == 0;

    public static BasicConfigForm From(string config)
    {
        var parsed = Core.Config.WireGuardConfig.Parse(config);
        var peer = parsed.PrimaryPeer;
        return new BasicConfigForm
        {
            PrivateKey = parsed.PrivateKey ?? "",
            Address = string.Join(", ", parsed.Address),
            Dns = string.Join(", ", Core.Config.WireGuardDns.Servers(parsed.Dns)),
            SearchDomains = string.Join(", ", Core.Config.WireGuardDns.SearchDomains(parsed.Dns)),
            PeerPublicKey = peer?.PublicKey ?? "",
            PresharedKey = peer?.PresharedKey ?? "",
            Endpoint = peer?.Endpoint ?? "",
            AllowedIPs = string.Join(", ", peer?.AllowedIPs ?? []),
            PersistentKeepalive = peer?.PersistentKeepalive?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "",
        };
    }

    public string ToConfig()
    {
        var dns = Core.Config.WireGuardDns.Compose(Dns, SearchDomains).Line;
        var lines = new List<string> { "[Interface]", $"PrivateKey = {PrivateKey.Trim()}", $"Address = {Address.Trim()}" };
        if (dns.Length > 0) lines.Add($"DNS = {dns}");
        lines.AddRange(["", "[Peer]", $"PublicKey = {PeerPublicKey.Trim()}"]);
        if (PresharedKey.Trim().Length > 0) lines.Add($"PresharedKey = {PresharedKey.Trim()}");
        lines.Add($"Endpoint = {Endpoint.Trim()}");
        lines.Add($"AllowedIPs = {AllowedIPs.Trim()}");
        if (PersistentKeepalive.Trim().Length > 0) lines.Add($"PersistentKeepalive = {PersistentKeepalive.Trim()}");
        return string.Join("\n", lines) + "\n";
    }
}
