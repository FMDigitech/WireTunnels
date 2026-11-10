using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;
using System.Text.Json;
using WireTunnels.Contracts;

namespace WireTunnels.Client;

/// Administrator actions for shared tunnels (the macOS AuthorizationRef). The app runs with the user's filtered
/// token, so the service sees a non-elevated caller; each admin request is relayed through `wiretunnels elevated`,
/// started through UAC, which talks to the pipe with the elevated token.
[SupportedOSPlatform("windows")]
public static partial class Elevation
{
    private const int TokenElevationType = 18, Limited = 3, Cancelled = 1223;
    /// Base64 of the request on the command line (32,767 characters at most).
    private const int MaxEncodedRequest = 30_000;

    /// The process already has an elevated token: requests go straight to the pipe.
    public static bool IsElevated { get; } = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);

    /// An administrator account (elevated, or with a split token UAC can elevate): admin controls are shown.
    /// shortcut: standard users never see them, although UAC could take an administrator's password; add an
    /// "administer as another user" action if shared PCs need it.
    public static bool CanAdminister { get; } = IsElevated || ElevationType() == Limited;

    private static int ElevationType()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return GetTokenInformation(identity.Token, TokenElevationType, out var type, sizeof(int), out _) ? type : 0;
    }

    /// One request through the elevated helper. Throws ServiceException with the service's error, or when the prompt is declined.
    public static async Task<Response> RelayAsync(Request request, CancellationToken ct = default)
    {
        var cli = Path.Combine(AppContext.BaseDirectory, "wiretunnels.exe");
        if (!File.Exists(cli)) throw new ServiceException("wiretunnels.exe was not found next to the app. Reinstall WireTunnels.");
        var encoded = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(request, Protocol.Json));
        if (encoded.Length > MaxEncodedRequest) throw new ServiceException("This configuration is too large for an administrator request.");

        // The helper may only write under %LOCALAPPDATA%\WireTunnels (it checks); the folder is the user's own.
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WireTunnels", "elevated");
        Directory.CreateDirectory(folder);
        var responseFile = Path.Combine(folder, $"{Guid.NewGuid():N}.json");
        try
        {
            using var process = Process.Start(new ProcessStartInfo(cli)
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
                Arguments = $"elevated {encoded} \"{responseFile}\"",
            }) ?? throw new ServiceException("The administrator helper did not start.");
            await process.WaitForExitAsync(ct);
            if (!File.Exists(responseFile)) throw new ServiceException($"The administrator helper failed (exit code {process.ExitCode}).");
            return JsonSerializer.Deserialize<Response>(await File.ReadAllBytesAsync(responseFile, ct), Protocol.Json)
                ?? throw new ServiceException("The administrator helper returned nothing.");
        }
        catch (Win32Exception e) when (e.NativeErrorCode == Cancelled)
        {
            throw new ServiceException("The administrator prompt was declined.");
        }
        finally
        {
            File.Delete(responseFile);
        }
    }

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returned);
}
