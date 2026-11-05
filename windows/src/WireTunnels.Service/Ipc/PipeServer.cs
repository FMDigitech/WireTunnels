using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using WireTunnels.Contracts;

namespace WireTunnels.Service.Ipc;

/// Serves the local pipe (the macOS NSXPCListener). Each connection is identified by the
/// client's token; requests on it are handled one at a time.
[SupportedOSPlatform("windows")]
internal sealed partial class PipeServer(RequestDispatcher dispatcher, ILogger<PipeServer> log) : BackgroundService
{
    private const int MaxInstances = 16;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var first = true;
        while (!stoppingToken.IsCancellationRequested)
        {
            // FirstPipeInstance on the first instance fails if anyone else already owns the name (pipe squatting).
            var pipe = Create(first);
            first = false;
            try
            {
                await pipe.WaitForConnectionAsync(stoppingToken);
            }
            catch
            {
                await pipe.DisposeAsync();
                throw;
            }
            _ = ServeAsync(pipe, stoppingToken);
        }
    }

    private async Task ServeAsync(NamedPipeServerStream pipe, CancellationToken ct)
    {
        await using var _ = pipe;
        try
        {
            if (!ClientImageIsTrusted(pipe))
            {
                log.LogWarning("Rejected a pipe client outside the WireTunnels install directory");
                return;
            }
            var client = Identify(pipe);
            while (await Protocol.ReadAsync<Request>(pipe, ct) is { } request)
                await Protocol.WriteAsync(pipe, await dispatcher.HandleAsync(request, client, ct), ct);
        }
        catch (Exception e) when (e is IOException or InvalidDataException or System.Text.Json.JsonException)
        {
            log.LogDebug(e, "Pipe client dropped");
        }
        catch (OperationCanceledException) { }
    }

    private static NamedPipeServerStream Create(bool first)
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null),
            PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
            PipeAccessRights.FullControl, AccessControlType.Deny));
        var options = PipeOptions.Asynchronous | (first ? PipeOptions.FirstPipeInstance : 0);
        return NamedPipeServerStreamAcl.Create(Protocol.PipeName, PipeDirection.InOut, MaxInstances,
            PipeTransmissionMode.Byte, options, 0, 0, security);
    }

    private static ClientIdentity Identify(NamedPipeServerStream pipe)
    {
        ClientIdentity? identity = null;
        pipe.RunAsClient(() =>
        {
            using var token = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
            // Under UAC a non-elevated admin token has Administrators as deny-only, so IsInRole is false.
            identity = new ClientIdentity(token.User!.Value, token.Name,
                new WindowsPrincipal(token).IsInRole(WindowsBuiltInRole.Administrator));
        });
        return identity!;
    }

    /// Defense in depth: the client executable must live in the service's own directory,
    /// which only administrators can write. Authorization itself is per user (see RequestDispatcher).
    private static bool ClientImageIsTrusted(NamedPipeServerStream pipe)
    {
#if DEBUG
        return true; // dev builds run the CLI from its own bin folder
#else
        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid)) return false;
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById((int)pid);
            var image = process.MainModule?.FileName;
            return image is not null && string.Equals(Path.GetDirectoryName(Path.GetFullPath(image)),
                Path.GetFullPath(AppContext.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
#endif
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint processId);
}
