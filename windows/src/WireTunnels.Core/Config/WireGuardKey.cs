using Org.BouncyCastle.Math.EC.Rfc7748;
using Org.BouncyCastle.Security;

namespace WireTunnels.Core.Config;

/// X25519 keys in WireGuard base64 form. .NET has no built-in X25519, so this uses BouncyCastle.
public static class WireGuardKey
{
    public const int KeyLength = 32;

    public static byte[]? Decode(string base64)
    {
        try
        {
            var raw = Convert.FromBase64String(base64.Trim());
            return raw.Length == KeyLength ? raw : null;
        }
        catch (FormatException) { return null; }
    }

    public static bool IsValid(string base64) => Decode(base64) is not null;

    /// Derives the base64 public key from a base64 private key, or null when it is not a key.
    public static string? PublicKey(string privateKey)
    {
        if (Decode(privateKey) is not { } raw) return null;
        var pub = new byte[KeyLength];
        X25519.ScalarMultBase(raw, 0, pub, 0);
        return Convert.ToBase64String(pub);
    }

    public static (string PrivateKey, string PublicKey) Generate()
    {
        var priv = new byte[KeyLength];
        X25519.GeneratePrivateKey(new SecureRandom(), priv);
        return (Convert.ToBase64String(priv), PublicKey(Convert.ToBase64String(priv))!);
    }
}
