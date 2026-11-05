using System.Globalization;
using System.Text;

namespace WireTunnels.Core.Config;

/// Port of WireTunnelsHelper/ConfigName.swift: display names and file/adapter aliases.
public static class ConfigName
{
    public const int MaxDisplayLength = 50;
    private const string AllowedAliasCharacters =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-";

    /// Trimmed, at most 50 user-perceived characters.
    public static string DisplayName(string name)
    {
        var trimmed = name.Trim();
        var info = new StringInfo(trimmed);
        return info.LengthInTextElements <= MaxDisplayLength
            ? trimmed
            : info.SubstringByTextElements(0, MaxDisplayLength);
    }

    /// 1-15 safe ASCII characters, identical to the macOS alias so configs and
    /// tunnel names stay interchangeable between platforms.
    public static string FileBaseName(string displayName)
    {
        var name = DisplayName(displayName).Normalize(NormalizationForm.FormC);
        var baseName = name.EndsWith(".conf", StringComparison.Ordinal) ? name[..^".conf".Length] : name;

        var safe = new StringBuilder();
        foreach (var rune in baseName.EnumerateRunes())
            safe.Append(rune.IsAscii && AllowedAliasCharacters.Contains((char)rune.Value) ? (char)rune.Value : '_');
        var safeBase = safe.ToString().Replace("..", "__", StringComparison.Ordinal);

        // A trailing dot would create ".." when the .conf extension is appended.
        var needsHash = baseName.Length == 0 || baseName.EndsWith('.') || safeBase != baseName
            || Encoding.UTF8.GetByteCount(baseName) > 15;
        if (!needsHash) return baseName;

        uint hash = 2166136261;
        foreach (var b in Encoding.UTF8.GetBytes(baseName.Length == 0 ? name : baseName))
            hash = unchecked((hash ^ b) * 16777619);
        var suffix = (hash & 0xFFFFFF).ToString("x6", CultureInfo.InvariantCulture);
        var prefix = safeBase.Length == 0 ? "tunnel" : safeBase[..Math.Min(safeBase.Length, 15 - suffix.Length - 1)];
        return $"{prefix}-{suffix}";
    }

    public static bool IsValidAlias(string alias) =>
        alias.Length is >= 1 and <= 15
        && !alias.Contains("..", StringComparison.Ordinal)
        && alias.All(c => AllowedAliasCharacters.Contains(c));
}
