using System.Security.AccessControl;
using System.Security.Principal;

namespace WireTunnels.Service.Managed;

/// %ProgramData%\WireTunnels: only SYSTEM and Administrators can open it, and everything below inherits that ACL.
[System.Runtime.Versioning.SupportedOSPlatform("windows")]
internal static class SecureFolder
{
    private static readonly SecurityIdentifier LocalSystem = new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier Administrators = new(WellKnownSidType.BuiltinAdministratorsSid, null);

    public static string Root { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WireTunnels");

    /// ProgramData lets any user create folders: a WireTunnels folder someone else created is refused,
    /// and ours always gets a protected ACL (no inheritance from ProgramData).
    public static void Ensure()
    {
        var security = new DirectorySecurity();
        security.SetOwner(Administrators);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { LocalSystem, Administrators })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        var info = new DirectoryInfo(Root);
        if (!info.Exists)
        {
            info.Create(security);
            return;
        }
        var owner = info.GetAccessControl().GetOwner(typeof(SecurityIdentifier));
        if (owner != LocalSystem && owner != Administrators)
            throw new UnauthorizedAccessException($"{Root} is owned by another account; remove it so the service can recreate it");
        info.SetAccessControl(security);
    }

    public static void WriteAtomically(string path, string contents) => WriteAtomically(path, System.Text.Encoding.UTF8.GetBytes(contents));

    public static void WriteAtomically(string path, byte[] contents)
    {
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, contents);
        File.Move(temp, path, overwrite: true);
    }
}
