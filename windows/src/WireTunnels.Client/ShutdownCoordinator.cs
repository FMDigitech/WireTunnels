namespace WireTunnels.Client;

public interface IShutdownClient
{
    void BeginShutdown();
    Task CancelShutdownAsync();
    Task<bool> WaitForPendingOperationsAsync();
    Task<bool> RefreshForShutdownAsync();
    Task<bool> DisconnectForShutdownAsync();
    Task<bool> RestoreNetworkSettingsForShutdownAsync();
    bool HasActiveTunnels { get; }
}

/// Port of TunnelShutdownCoordinator.swift: Quit must not race a connect, and must not exit
/// after a failed cleanup (the user gets Retry / Cancel instead).
public sealed class ShutdownCoordinator
{
    private Task<bool>? _pending;

    public string? FailureReason { get; private set; }

    public async Task CancelAsync(IShutdownClient client)
    {
        if (_pending is { } pending) await pending;
        await client.CancelShutdownAsync();
        FailureReason = null;
    }

    public async Task<bool> PrepareAsync(IShutdownClient client)
    {
        if (_pending is { } running) return await running;
        FailureReason = null;
        client.BeginShutdown();
        _pending = RunAsync(client);
        try { return await _pending; }
        finally { _pending = null; }
    }

    private async Task<bool> RunAsync(IShutdownClient client)
    {
        if (!await client.WaitForPendingOperationsAsync())
            return Fail("A tunnel operation is still running. Wait for it to finish and retry.");
        if (!await client.RefreshForShutdownAsync())
            return Fail("Unable to confirm the current tunnel state.");
        if (!await client.DisconnectForShutdownAsync())
            return Fail("One or more tunnels could not be disconnected.");
        if (!await client.RefreshForShutdownAsync() || client.HasActiveTunnels)
            return Fail("A tunnel is still connected, or its disconnected state could not be confirmed.");
        if (!await client.RestoreNetworkSettingsForShutdownAsync())
            return Fail("Network settings could not be restored.");
        return true;
    }

    private bool Fail(string reason)
    {
        FailureReason = reason;
        return false;
    }
}
