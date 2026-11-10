using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using WireTunnels.Core.Models;
using WireTunnels.Core.Storage;

namespace WireTunnels.Service.Managed;

/// Shared tunnels as the service keeps them (the macOS /Library/Application Support/WireTunnels/managed); faked in tests.
/// A record is a Tunnel with Scope = Managed whose ConfigPath holds its adapter alias: the config never leaves the service.
internal interface IManagedStore
{
    List<Tunnel> Load();
    void Save(IReadOnlyList<Tunnel> records);
    string ReadConfig(Guid id);
    void WriteConfig(Guid id, string contents);
    void DeleteConfig(Guid id);
    SystemSettings LoadSettings();
    void SaveSettings(SystemSettings settings);
}

/// %ProgramData%\WireTunnels\managed\{tunnels.json, settings.json, configs\<id>.conf.dpapi}, inside the
/// SYSTEM + Administrators folder. Configs are also DPAPI-encrypted for the machine, so a copied disk
/// image or backup of the folder does not expose their private keys on another PC.
[SupportedOSPlatform("windows")]
internal sealed class ProgramDataManagedStore : IManagedStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("WireTunnels.Managed.v1");
    private static string Directory => Path.Combine(SecureFolder.Root, "managed");
    private static string Configs => Path.Combine(Directory, "configs");
    private static string TunnelsFile => Path.Combine(Directory, "tunnels.json");
    private static string SettingsFile => Path.Combine(Directory, "settings.json");
    private static string ConfigFile(Guid id) => Path.Combine(Configs, $"{id:N}.conf.dpapi");

    public List<Tunnel> Load() => Read<List<Tunnel>>(TunnelsFile) ?? [];

    public void Save(IReadOnlyList<Tunnel> records) => Write(TunnelsFile, records);

    public SystemSettings LoadSettings() => Read<SystemSettings>(SettingsFile) ?? new();

    public void SaveSettings(SystemSettings settings) => Write(SettingsFile, settings);

    public string ReadConfig(Guid id)
    {
        Prepare();
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(ConfigFile(id)), Entropy, DataProtectionScope.LocalMachine)); }
        catch (FileNotFoundException) { throw new InvalidDataException("The shared tunnel's configuration is missing."); }
        catch (CryptographicException) { throw new InvalidDataException("The shared tunnel's configuration could not be decrypted on this PC."); }
    }

    public void WriteConfig(Guid id, string contents)
    {
        Prepare();
        SecureFolder.WriteAtomically(ConfigFile(id), ProtectedData.Protect(Encoding.UTF8.GetBytes(contents), Entropy, DataProtectionScope.LocalMachine));
    }

    public void DeleteConfig(Guid id)
    {
        Prepare();
        File.Delete(ConfigFile(id));
    }

    private static T? Read<T>(string file) where T : class
    {
        if (!File.Exists(file)) return null;
        Prepare();
        return JsonSerializer.Deserialize<T>(File.ReadAllText(file), CoreJson.Options);
    }

    private static void Write<T>(string file, T value)
    {
        Prepare();
        SecureFolder.WriteAtomically(file, JsonSerializer.Serialize(value, CoreJson.Options));
    }

    /// The subfolders inherit the protected ACL of the root, which is re-checked first.
    private static void Prepare()
    {
        SecureFolder.Ensure();
        System.IO.Directory.CreateDirectory(Configs);
    }
}
