using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography.X509Certificates;

namespace WireTunnels.Contracts;

/// Authenticode check of a file with an embedded signature: a valid chain to a trusted root
/// (WinVerifyTrust) and a leaf certificate issued to the expected publisher. A valid signature
/// alone is not enough: any signed DLL would pass.
[SupportedOSPlatform("windows")]
public static partial class WinTrust
{
    /// null when the file is signed by `publisher`, otherwise why it is not.
    public static string? Verify(string path, string publisher)
    {
        var status = WinVerifyTrustFile(path);
        if (status != 0) return $"{Path.GetFileName(path)} has no valid Authenticode signature (0x{status:X8})";
        try
        {
#pragma warning disable SYSLIB0057 // the signer of an embedded signature; no replacement in .NET 10
            using var signer = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
            var name = signer.GetNameInfo(X509NameType.SimpleName, forIssuer: false);
            return string.Equals(name, publisher, StringComparison.Ordinal)
                ? null
                : $"{Path.GetFileName(path)} is signed by {name}, not {publisher}";
        }
        catch (System.Security.Cryptography.CryptographicException e)
        {
            return $"{Path.GetFileName(path)}: unable to read the signer ({e.Message})";
        }
    }

    private static readonly Guid GenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
    private const uint UiNone = 2, RevokeNone = 0, ChoiceFile = 1, StateVerify = 1, StateClose = 2;
    // Never fetch revocation data over the network: the service also starts offline.
    private const uint CacheOnlyUrlRetrieval = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInfo
    {
        public uint Size;
        public IntPtr FilePath;
        public IntPtr File;
        public IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Data
    {
        public uint Size;
        public IntPtr PolicyCallbackData;
        public IntPtr SipClientData;
        public uint UiChoice;
        public uint RevocationChecks;
        public uint UnionChoice;
        public IntPtr File;
        public uint StateAction;
        public IntPtr StateData;
        public IntPtr UrlReference;
        public uint ProvFlags;
        public uint UiContext;
        public IntPtr SignatureSettings;
    }

    private static unsafe int WinVerifyTrustFile(string path)
    {
        var filePath = Marshal.StringToHGlobalUni(path);
        try
        {
            var file = new FileInfo { Size = (uint)sizeof(FileInfo), FilePath = filePath };
            var data = new Data
            {
                Size = (uint)sizeof(Data),
                UiChoice = UiNone,
                RevocationChecks = RevokeNone,
                UnionChoice = ChoiceFile,
                File = (IntPtr)(&file),
                StateAction = StateVerify,
                ProvFlags = CacheOnlyUrlRetrieval,
            };
            var action = GenericVerifyV2;
            var result = WinVerifyTrust(-1, ref action, ref data); // INVALID_HANDLE_VALUE: no UI
            data.StateAction = StateClose;
            WinVerifyTrust(-1, ref action, ref data);
            return result;
        }
        finally
        {
            Marshal.FreeHGlobal(filePath);
        }
    }

    [LibraryImport("wintrust.dll")]
    private static partial int WinVerifyTrust(nint window, ref Guid action, ref Data data);
}
