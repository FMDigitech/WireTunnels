using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace WireTunnels.Core.Net;

/// A numeric IPv4/IPv6 network, masked to its prefix. Merges the macOS IPSubnet and
/// IPPrefix types. Parsing is strict and never performs a DNS lookup: IPAddress.TryParse
/// alone accepts "1", "0x7f.1" or "010.0.0.1", which must not reach routes or firewall rules.
public readonly record struct IPPrefix : IComparable<IPPrefix>
{
    private readonly byte[] _bytes;

    public int Length { get; }
    public ReadOnlySpan<byte> Bytes => _bytes;
    public AddressFamily Family => _bytes.Length == 4 ? AddressFamily.InterNetwork : AddressFamily.InterNetworkV6;
    public bool IsIPv4 => _bytes.Length == 4;
    public IPAddress Address => new(_bytes);

    private IPPrefix(byte[] bytes, int length)
    {
        _bytes = Mask(bytes, length);
        Length = length;
    }

    /// "a.b.c.d/n", "x::y/n", or a bare address (host prefix). No scope ids.
    public static bool TryParse(string? text, out IPPrefix prefix)
    {
        prefix = default;
        if (text is null) return false;
        var parts = text.Trim().Split('/');
        if (parts.Length is < 1 or > 2 || !TryParseAddress(parts[0], out var address)) return false;
        var bytes = address.GetAddressBytes();
        var length = bytes.Length * 8;
        if (parts.Length == 2)
        {
            if (parts[1].Length is 0 or > 3 || !parts[1].All(char.IsAsciiDigit)
                || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out length)
                || length > bytes.Length * 8) return false;
        }
        prefix = new IPPrefix(bytes, length);
        return true;
    }

    public static IPPrefix Parse(string text) =>
        TryParse(text, out var prefix) ? prefix : throw new FormatException($"Invalid IP prefix: {text}");

    /// Unambiguous numeric address: dotted IPv4 with 4 decimal octets and no leading zeros,
    /// or IPv6 (optionally with an IPv4 tail, same octet rules). Scope ids are rejected.
    public static bool TryParseAddress(string? text, out IPAddress address)
    {
        address = IPAddress.None;
        if (string.IsNullOrEmpty(text) || text.Contains('%') || text.Contains('\0')) return false;
        if (text.Contains('.'))
        {
            var dotted = text[(text.LastIndexOf(':') + 1)..];
            var octets = dotted.Split('.');
            if (octets.Length != 4 || !octets.All(o =>
                    o.Length is >= 1 and <= 3 && o.All(char.IsAsciiDigit)
                    && (o.Length == 1 || o[0] != '0') && int.Parse(o, CultureInfo.InvariantCulture) <= 255))
                return false;
        }
        else if (!text.Contains(':')) return false;

        if (!IPAddress.TryParse(text, out var parsed)) return false;
        if (text.Contains(':') != (parsed.AddressFamily == AddressFamily.InterNetworkV6)) return false;
        address = parsed;
        return true;
    }

    public static bool IsValidCidr(string text) => text.Contains('/') && TryParse(text, out _);

    public static bool IsValidAddress(string text) => TryParseAddress(text, out _);

    public bool Contains(IPPrefix other)
    {
        if (Family != other.Family || Length > other.Length) return false;
        return Mask(other._bytes, Length).AsSpan().SequenceEqual(_bytes);
    }

    /// Whether a bare address (an IPv6 link-local may carry a simple %scope) is inside this network.
    public bool ContainsAddress(string address)
    {
        var numeric = address;
        var percent = address.IndexOf('%');
        if (percent >= 0)
        {
            var scope = address[(percent + 1)..];
            if (IsIPv4 || scope.Length == 0 || !scope.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-' or '.'))
                return false;
            numeric = address[..percent];
        }
        return TryParseAddress(numeric, out var ip) && ip.GetAddressBytes().Length == _bytes.Length
            && Contains(new IPPrefix(ip.GetAddressBytes(), _bytes.Length * 8));
    }

    public bool Overlaps(IPPrefix other) => Contains(other) || other.Contains(this);

    public bool IsHost => Length == _bytes.Length * 8;

    public int CompareTo(IPPrefix other)
    {
        if (_bytes.Length != other._bytes.Length) return _bytes.Length.CompareTo(other._bytes.Length);
        var bytes = _bytes.AsSpan().SequenceCompareTo(other._bytes);
        return bytes != 0 ? bytes : Length.CompareTo(other.Length);
    }

    public bool Equals(IPPrefix other) =>
        Length == other.Length && (_bytes ?? []).AsSpan().SequenceEqual(other._bytes ?? []);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.AddBytes(_bytes ?? []);
        hash.Add(Length);
        return hash.ToHashCode();
    }

    public override string ToString() => $"{Address}/{Length}";

    /// Parsed, deduplicated and sorted canonical CIDRs.
    public static IReadOnlyList<string> Normalized(IEnumerable<string> values, int maximum = 100_000)
    {
        var list = values.ToList();
        if (list.Count > maximum) throw new FormatException("Too many prefixes");
        return list.Select(Parse).Distinct().Order().Select(p => p.ToString()).ToList();
    }

    private static byte[] Mask(byte[] bytes, int length)
    {
        var masked = new byte[bytes.Length];
        for (var i = 0; i < bytes.Length; i++)
        {
            var bits = Math.Clamp(length - i * 8, 0, 8);
            masked[i] = bits == 0 ? (byte)0 : (byte)(bytes[i] & (0xFF << (8 - bits)));
        }
        return masked;
    }
}
