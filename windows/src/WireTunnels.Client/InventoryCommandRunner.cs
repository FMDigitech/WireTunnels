using System.Diagnostics;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;

namespace WireTunnels.Client;

/// Port of InventoryError: messages shown to the user as they are.
public sealed class InventoryException(string message) : Exception(message)
{
    public static InventoryException InvalidOutput() => new(IPPrefix.InventoryOutputMessage);
    public static InventoryException InvalidCommand() => new("Choose an executable using an absolute path. Arguments are passed individually, without a shell.");
    public static InventoryException CommandFailed() => new("The inventory command failed. The last successful inventory was kept.");
    public static InventoryException TimedOut() => new("The inventory command exceeded its 60-second deadline.");
    public static InventoryException Stale() => new("The tunnel changed while its inventory was being refreshed.");
}

/// Runs an inventory command; faked in tests.
public interface IInventoryRunner
{
    Task<IReadOnlyList<string>> RunAsync(InventoryCommand command, CancellationToken ct);
}

/// Port of InventoryCommandService: the command runs as the signed-in user, directly (no shell), with
/// stdin closed and stderr discarded; at most 60 s and 8 MiB of stdout, which must be IPs/CIDRs.
public sealed class InventoryCommandRunner : IInventoryRunner
{
    private const int MaxOutput = 8 * 1024 * 1024;
    private readonly TimeSpan _timeout;

    public InventoryCommandRunner(TimeSpan? timeout = null) => _timeout = timeout ?? TimeSpan.FromSeconds(60);

    public static bool IsValid(InventoryCommand command) =>
        Path.IsPathFullyQualified(command.Executable) && File.Exists(command.Executable) && !command.Executable.Contains('\0')
        && command.Arguments.Count <= 1024 && command.Arguments.Sum(a => a.Length + 1) <= 128 * 1024 && command.Arguments.All(a => !a.Contains('\0'));

    public async Task<IReadOnlyList<string>> RunAsync(InventoryCommand command, CancellationToken ct)
    {
        if (!IsValid(command)) throw InventoryException.InvalidCommand();
        var info = new ProcessStartInfo(command.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in command.Arguments) info.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = info };
        try { process.Start(); }
        catch (System.ComponentModel.Win32Exception) { throw InventoryException.InvalidCommand(); }
        process.StandardInput.Close();
        process.ErrorDataReceived += (_, _) => { }; // drained so a chatty stderr cannot block the command
        process.BeginErrorReadLine();

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(_timeout);
        try
        {
            var output = new MemoryStream();
            var buffer = new byte[65536];
            int read;
            while ((read = await process.StandardOutput.BaseStream.ReadAsync(buffer, deadline.Token)) > 0)
            {
                output.Write(buffer, 0, read);
                if (output.Length > MaxOutput) throw InventoryException.InvalidOutput();
            }
            await process.WaitForExitAsync(deadline.Token);
            if (process.ExitCode != 0) throw InventoryException.CommandFailed();
            try { return IPPrefix.ParseInventoryOutput(output.GetBuffer().AsSpan(0, (int)output.Length)); }
            catch (FormatException e) { throw new InventoryException(e.Message); }
        }
        catch (Exception e)
        {
            // Whatever went wrong, nothing the command started keeps running.
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            if (e is OperationCanceledException && !ct.IsCancellationRequested) throw InventoryException.TimedOut();
            throw;
        }
    }
}
