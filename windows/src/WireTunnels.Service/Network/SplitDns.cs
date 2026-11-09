using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32;

namespace WireTunnels.Service.Network;

/// One Name Resolution Policy Table rule: namespaces (".corp.example") answered by `Servers`.
internal sealed record NrptRule(IReadOnlyList<string> Names, IReadOnlyList<string> Servers, string Comment);

/// The NRPT registry; faked in tests.
internal interface INrptStore
{
    /// Local rules by registry key name.
    IReadOnlyDictionary<string, NrptRule> Rules();
    /// True when Group Policy defines NRPT rules: Windows then ignores the local ones.
    bool ManagedByPolicy();
    void Write(string key, NrptRule rule);
    void Delete(string key);
    /// Makes the DNS client pick up the change.
    void Refresh();
}

/// The /etc/resolver of the macOS helper (ResolverStore): one NRPT rule per domain, owned per user
/// through a comment marker. Rules written by anyone else are never modified or removed, and a domain
/// they already cover is reported as a conflict.
internal static class SplitDns
{
    public const string MarkerPrefix = "Managed by WireTunnels";
    private const string KeyPrefix = "WireTunnels-";

    public static string Marker(string sid) => $"{MarkerPrefix} ({sid})";

    /// Port of HelperTool.isValidResolverDomain.
    public static bool IsValidDomain(string value) =>
        value.Length is >= 1 and <= 253 && !value.StartsWith('.') && !value.EndsWith('.') && !value.StartsWith('-')
        && !value.Contains("..") && value.All(c => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '.' or '-');

    /// Makes the caller's rules equal `desired` (domain -> servers); returns the conflicting domains.
    public static IReadOnlyList<string> Sync(INrptStore store, string sid, IReadOnlyDictionary<string, IReadOnlyList<string>> desired)
    {
        var marker = Marker(sid);
        if (desired.Count > 0 && store.ManagedByPolicy())
            throw new InvalidOperationException("Split DNS is unavailable because Group Policy manages DNS name resolution rules on this PC");
        var rules = store.Rules();
        var conflicts = new List<string>();
        foreach (var (domain, servers) in desired)
        {
            var key = KeyPrefix + domain;
            var foreign = rules.Any(r => r.Value.Comment != marker
                && r.Value.Names.Any(n => string.Equals(n.TrimStart('.'), domain, StringComparison.OrdinalIgnoreCase)));
            if (foreign)
            {
                conflicts.Add(domain);
                continue;
            }
            store.Write(key, new NrptRule(["." + domain], servers, marker));
        }
        foreach (var (key, rule) in rules)
            if (rule.Comment == marker && !(key.StartsWith(KeyPrefix, StringComparison.Ordinal) && desired.ContainsKey(key[KeyPrefix.Length..])))
                store.Delete(key);
        store.Refresh();
        return conflicts;
    }

    /// Removes every rule WireTunnels wrote, for any user: at service start no tunnel is running.
    public static void Clear(INrptStore store)
    {
        var removed = false;
        foreach (var (key, rule) in store.Rules())
            if (rule.Comment.StartsWith(MarkerPrefix, StringComparison.Ordinal) && key.StartsWith(KeyPrefix, StringComparison.Ordinal))
            {
                store.Delete(key);
                removed = true;
            }
        if (removed) store.Refresh();
    }
}

/// The local NRPT (what Add-DnsClientNrptRule writes).
[SupportedOSPlatform("windows")]
internal sealed partial class RegistryNrptStore : INrptStore
{
    private const string LocalPath = @"SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig";
    private const string PolicyPath = @"SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\DnsPolicyConfig";
    private const int ConfigOptionsGenericServers = 0x8;

    public IReadOnlyDictionary<string, NrptRule> Rules()
    {
        using var root = Registry.LocalMachine.OpenSubKey(LocalPath);
        var rules = new Dictionary<string, NrptRule>(StringComparer.OrdinalIgnoreCase);
        if (root is null) return rules;
        foreach (var name in root.GetSubKeyNames())
        {
            using var key = root.OpenSubKey(name);
            if (key is null) continue;
            rules[name] = new NrptRule(
                key.GetValue("Name") as string[] ?? [],
                ((key.GetValue("GenericDNSServers") as string) ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries),
                key.GetValue("Comment") as string ?? "");
        }
        return rules;
    }

    public bool ManagedByPolicy()
    {
        using var root = Registry.LocalMachine.OpenSubKey(PolicyPath);
        return root?.SubKeyCount > 0;
    }

    public void Write(string name, NrptRule rule)
    {
        using var key = Registry.LocalMachine.CreateSubKey($@"{LocalPath}\{name}", writable: true);
        key.SetValue("Name", rule.Names.ToArray(), RegistryValueKind.MultiString);
        key.SetValue("GenericDNSServers", string.Join(";", rule.Servers), RegistryValueKind.String);
        key.SetValue("ConfigOptions", ConfigOptionsGenericServers, RegistryValueKind.DWord);
        key.SetValue("Version", 2, RegistryValueKind.DWord);
        key.SetValue("IPSECCARestriction", "", RegistryValueKind.String);
        key.SetValue("Comment", rule.Comment, RegistryValueKind.String);
        key.SetValue("DisplayName", "WireTunnels split DNS", RegistryValueKind.String);
    }

    public void Delete(string name) => Registry.LocalMachine.DeleteSubKeyTree($@"{LocalPath}\{name}", throwOnMissingSubKey: false);

    [LibraryImport("dnsapi.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DnsFlushResolverCache();

    public void Refresh() => DnsFlushResolverCache();
}
