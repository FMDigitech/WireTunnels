using System.Globalization;
using WireTunnels.Core.Net;

namespace WireTunnels.Core.Config;

public sealed class WireGuardPeer
{
    public string? PublicKey { get; set; }
    public string? PresharedKey { get; set; }
    public string? Endpoint { get; set; }
    public List<string> AllowedIPs { get; } = [];
    public int? PersistentKeepalive { get; set; }
}

public enum ConfigError
{
    MissingPrivateKey, MissingAddress, MissingPeerPublicKey, MissingAllowedIPs,
    UnsupportedDirective, ControlCharacters, InvalidValue
}

public enum ConfigWarning
{
    MissingDns, MissingEndpoint, FullTunnel, Ipv4RoutedWithoutAddress, Ipv6RoutedWithoutAddress
}

public sealed record ConfigIssue(ConfigError Error, string Message);

/// Parsed `.conf`: the whole [Interface] and every [Peer] (wireguard-nt needs all of them),
/// plus the same validation errors and warnings as the macOS WireGuardConfigParser.
public sealed class WireGuardConfig
{
    public string? PrivateKey { get; set; }
    public List<string> Address { get; } = [];
    public List<string> Dns { get; } = [];
    public int? ListenPort { get; set; }
    public int? Mtu { get; set; }
    public List<WireGuardPeer> Peers { get; } = [];

    public List<ConfigIssue> Errors { get; } = [];
    public List<ConfigWarning> Warnings { get; } = [];
    public bool IsValid => Errors.Count == 0;

    /// First peer: what the UI shows as "the" peer, as on macOS.
    public WireGuardPeer? PrimaryPeer => Peers.FirstOrDefault();

    public static WireGuardConfig Parse(string text)
    {
        var config = new WireGuardConfig();
        switch (ConfigSafety.FirstViolation(text))
        {
            case { Kind: ConfigViolationKind.ControlCharacter }:
                config.Errors.Add(new(ConfigError.ControlCharacters, "Configuration contains control characters"));
                break;
            case { Kind: ConfigViolationKind.Hook, Hook: var hook }:
                var name = hook switch { "preup" => "PreUp", "postup" => "PostUp", "predown" => "PreDown", _ => "PostDown" };
                config.Errors.Add(new(ConfigError.UnsupportedDirective,
                    $"{name} is not supported because it executes commands with administrator privileges"));
                break;
        }

        var section = "";
        WireGuardPeer? peer = null;
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            if (line.StartsWith('['))
            {
                section = line.ToLowerInvariant();
                peer = null;
                if (section == "[peer]") config.Peers.Add(peer = new WireGuardPeer());
                continue;
            }

            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var key = line[..eq].Trim().ToLowerInvariant();
            var value = StripComment(line[(eq + 1)..]).Trim();

            if (section == "[interface]")
            {
                switch (key)
                {
                    case "privatekey": config.PrivateKey = NonEmpty(value); break;
                    case "address": config.Address.AddRange(List(value)); break;
                    case "dns": config.Dns.AddRange(List(value)); break;
                    case "listenport": config.ListenPort = config.ParseInt(value, "ListenPort", 0, 65535); break;
                    case "mtu": config.Mtu = config.ParseInt(value, "MTU", 576, 65535); break;
                }
            }
            else if (peer is not null)
            {
                switch (key)
                {
                    case "publickey": peer.PublicKey = NonEmpty(value); break;
                    case "presharedkey": peer.PresharedKey = NonEmpty(value); break;
                    case "endpoint": peer.Endpoint = NonEmpty(value); break;
                    case "allowedips": peer.AllowedIPs.AddRange(List(value)); break;
                    case "persistentkeepalive":
                        peer.PersistentKeepalive = value.Equals("off", StringComparison.OrdinalIgnoreCase)
                            ? 0 : config.ParseInt(value, "PersistentKeepalive", 0, 65535);
                        break;
                }
            }
        }

        config.Validate();
        return config;
    }

    private void Validate()
    {
        if (PrivateKey is null) Errors.Add(new(ConfigError.MissingPrivateKey, "PrivateKey is missing"));
        else if (!WireGuardKey.IsValid(PrivateKey)) Errors.Add(new(ConfigError.InvalidValue, "PrivateKey is not a valid key"));
        if (Address.Count == 0) Errors.Add(new(ConfigError.MissingAddress, "Address is missing"));
        foreach (var a in Address.Where(a => !IPPrefix.TryParse(a, out _)))
            Errors.Add(new(ConfigError.InvalidValue, $"Invalid Address: {a}"));

        var primary = PrimaryPeer;
        if (primary?.PublicKey is null) Errors.Add(new(ConfigError.MissingPeerPublicKey, "Peer PublicKey is missing"));
        if (primary is null || primary.AllowedIPs.Count == 0)
            Errors.Add(new(ConfigError.MissingAllowedIPs, "AllowedIPs is missing"));
        foreach (var p in Peers)
        {
            if (p.PublicKey is { } pk && !WireGuardKey.IsValid(pk)) Errors.Add(new(ConfigError.InvalidValue, "Peer PublicKey is not a valid key"));
            if (p.PresharedKey is { } psk && !WireGuardKey.IsValid(psk)) Errors.Add(new(ConfigError.InvalidValue, "PresharedKey is not a valid key"));
            if (p.Endpoint is { } ep && Endpoint.TryParse(ep) is null) Errors.Add(new(ConfigError.InvalidValue, $"Invalid Endpoint: {ep}"));
            foreach (var ip in p.AllowedIPs.Where(ip => !IPPrefix.TryParse(ip, out _)))
                Errors.Add(new(ConfigError.InvalidValue, $"Invalid AllowedIPs entry: {ip}"));
        }

        if (Dns.Count == 0) Warnings.Add(ConfigWarning.MissingDns);
        if (primary?.Endpoint is null) Warnings.Add(ConfigWarning.MissingEndpoint);
        var allowed = Peers.SelectMany(p => p.AllowedIPs).ToList();
        if (IPFamilyRouting.RoutesAll(IPFamily.IPv4, allowed)) Warnings.Add(ConfigWarning.FullTunnel);
        foreach (var family in Enum.GetValues<IPFamily>())
            if (IPFamilyRouting.RoutesAll(family, allowed) && !IPFamilyRouting.HasAddress(family, Address))
                Warnings.Add(family == IPFamily.IPv4 ? ConfigWarning.Ipv4RoutedWithoutAddress : ConfigWarning.Ipv6RoutedWithoutAddress);
    }

    private int? ParseInt(string value, string field, int min, int max)
    {
        if (int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var n) && n >= min && n <= max) return n;
        Errors.Add(new(ConfigError.InvalidValue, $"Invalid {field}: {value}"));
        return null;
    }

    private static string StripComment(string value)
    {
        var hash = value.IndexOf('#');
        return hash >= 0 ? value[..hash] : value;
    }

    private static string? NonEmpty(string value) => value.Length == 0 ? null : value;

    private static IEnumerable<string> List(string value) =>
        value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
}

/// `host:port`, `[v6]:port` or `v4:port`. Host names are allowed (resolved by the service at connect).
public sealed record Endpoint(string Host, int Port)
{
    public static Endpoint? TryParse(string text)
    {
        string host, port;
        if (text.StartsWith('['))
        {
            var close = text.IndexOf(']');
            if (close < 0 || close + 1 >= text.Length || text[close + 1] != ':') return null;
            host = text[1..close];
            port = text[(close + 2)..];
            if (!IPPrefix.TryParseAddress(host, out _)) return null;
        }
        else
        {
            var colon = text.LastIndexOf(':');
            if (colon <= 0 || text.IndexOf(':') != colon) return null;
            host = text[..colon];
            port = text[(colon + 1)..];
            if (!IPPrefix.IsValidAddress(host) && WireGuardDns.NormalizedDomain(host) is null) return null;
        }
        return int.TryParse(port, NumberStyles.None, CultureInfo.InvariantCulture, out var p) && p is >= 1 and <= 65535
            ? new Endpoint(host, p) : null;
    }
}
