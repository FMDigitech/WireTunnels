using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using WireTunnels.Core.Config;

namespace WireTunnels.Client;

/// Encrypts config files at rest. DPAPI in the app, a fake in tests.
public interface IConfigProtector
{
    byte[] Protect(byte[] plain);
    byte[] Unprotect(byte[] protectedData);
}

/// DPAPI bound to the current Windows user: private keys are never on disk in clear text and
/// another user (or an offline copy of the disk without the user's credentials) cannot read them.
[SupportedOSPlatform("windows")]
public sealed class DpapiConfigProtector : IConfigProtector
{
    private static readonly byte[] Entropy = "WireTunnels.Config.v1"u8.ToArray();

    public byte[] Protect(byte[] plain) => ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
    public byte[] Unprotect(byte[] protectedData) => ProtectedData.Unprotect(protectedData, Entropy, DataProtectionScope.CurrentUser);
}

public sealed class ConfigStorageException(string message) : IOException(message)
{
    public static ConfigStorageException InvalidName() =>
        new("Enter a tunnel name without control characters (up to 50 characters).");

    public static ConfigStorageException AlreadyExists(string name) => new($"A tunnel named \"{name}\" already exists");
}

/// Port of ConfigStorageService.swift. A config is stored as `configs\<alias>.conf.dpapi`, where the
/// alias (ConfigName.FileBaseName) is also the wireguard-nt adapter name, exactly as on macOS.
public sealed class ConfigStore(string directory, IConfigProtector protector)
{
    public const string Extension = ".conf.dpapi";
    /// A WireGuard config is a few hundred bytes; anything this large is not one.
    public const int MaxConfigBytes = 256 * 1024;

    public string Directory { get; } = Path.GetFullPath(directory);

    /// The alias a stored config path encodes, or null for a path this store did not create.
    public string? AliasOf(string path)
    {
        if (!IsInside(path)) return null;
        var file = Path.GetFileName(path);
        if (!file.EndsWith(Extension, StringComparison.Ordinal)) return null;
        var alias = file[..^Extension.Length];
        return ConfigName.IsValidAlias(alias) ? alias : null;
    }

    public string PathFor(string displayName) => Path.Combine(Directory, ConfigName.FileBaseName(displayName) + Extension);

    public bool Exists(string displayName) => File.Exists(PathFor(displayName));

    /// Reads a `.conf` from anywhere the user picked; the content is validated by the caller.
    public static string ReadSource(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException("The file no longer exists.", path);
        if (info.Length > MaxConfigBytes) throw new InvalidDataException("This file is too large to be a WireGuard configuration.");
        return File.ReadAllText(path);
    }

    /// Saves `content` under the alias of `displayName` and returns the stored path.
    public string Save(string displayName, string content, bool replacingExisting = false)
    {
        var name = ConfigName.DisplayName(displayName);
        if (name.Length == 0 || name.Any(char.IsControl)) throw ConfigStorageException.InvalidName();
        var path = PathFor(name);
        if (File.Exists(path) && !replacingExisting) throw ConfigStorageException.AlreadyExists(name);
        System.IO.Directory.CreateDirectory(Directory); // Reset App Data removes the folder while the app runs
        var data = protector.Protect(Encoding.UTF8.GetBytes(content));
        var temporary = Path.Combine(Directory, $".{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, path, overwrite: replacingExisting);
        }
        catch (IOException) when (!replacingExisting && File.Exists(path))
        {
            throw ConfigStorageException.AlreadyExists(name);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
        return path;
    }

    public string Read(string path)
    {
        if (AliasOf(path) is null) throw new InvalidDataException("The tunnel's configuration is not in the WireTunnels config folder.");
        try
        {
            return Encoding.UTF8.GetString(protector.Unprotect(File.ReadAllBytes(path)));
        }
        catch (CryptographicException)
        {
            throw new InvalidDataException("The configuration could not be decrypted. It was saved by another Windows user or on another PC.");
        }
    }

    /// Restores exact bytes written earlier by `Save` (rollback of a failed edit).
    public byte[] ReadRaw(string path) =>
        AliasOf(path) is null ? throw new InvalidDataException("Not a WireTunnels config") : File.ReadAllBytes(path);

    public void WriteRaw(string path, byte[] data)
    {
        if (AliasOf(path) is null) throw new InvalidDataException("Not a WireTunnels config");
        File.WriteAllBytes(path, data);
    }

    /// Deletes only files this store owns: a damaged tunnels.json can never point it elsewhere.
    public void Delete(string path)
    {
        if (AliasOf(path) is not null && File.Exists(path)) File.Delete(path);
    }

    private bool IsInside(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            return string.Equals(Path.GetDirectoryName(full), Directory.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }
}
