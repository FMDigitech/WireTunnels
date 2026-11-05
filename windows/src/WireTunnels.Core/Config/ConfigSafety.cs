namespace WireTunnels.Core.Config;

public enum ConfigViolationKind { ControlCharacter, Hook }

public sealed record ConfigViolation(ConfigViolationKind Kind, string? Hook = null);

/// Port of ConfigSafety (WireGuardConfigParser.swift / HelperTool.swift).
/// Hook directives (PreUp/PostUp/PreDown/PostDown) would run commands as SYSTEM, so
/// they are rejected everywhere; control characters are rejected because parsers disagree on them.
/// Used by both the app (clear error at import) and the service (enforcement).
public static class ConfigSafety
{
    public static readonly IReadOnlySet<string> HookDirectives =
        new HashSet<string>(StringComparer.Ordinal) { "preup", "postup", "predown", "postdown" };

    public static ConfigViolation? FirstViolation(string text)
    {
        for (var i = 0; i < text.Length; i++)
        {
            int c = text[i];
            if (c is 0x09 or 0x0A) continue;
            if (c == 0x0D && i + 1 < text.Length && text[i + 1] == '\n') continue;
            if (c is <= 0x1F or (>= 0x7F and <= 0x9F) or 0x2028 or 0x2029)
                return new ConfigViolation(ConfigViolationKind.ControlCharacter);
        }

        foreach (var line in text.Split('\n'))
        {
            var hash = line.IndexOf('#');
            var stripped = hash >= 0 ? line[..hash] : line;
            var eq = stripped.IndexOf('=');
            var key = (eq >= 0 ? stripped[..eq] : stripped).Trim().ToLowerInvariant();
            if (HookDirectives.Contains(key)) return new ConfigViolation(ConfigViolationKind.Hook, key);
        }
        return null;
    }
}
