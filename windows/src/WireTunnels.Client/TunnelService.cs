using System.Runtime.Versioning;
using System.ServiceProcess;
using WireTunnels.Contracts;

namespace WireTunnels.Client;

/// What the app needs from the WireTunnels service (the macOS WireGuardCommandService); faked in tests.
public interface ITunnelService
{
    /// The service version, after checking that it speaks our protocol revision.
    Task<string> HandshakeAsync(CancellationToken ct = default);
    Task StartAsync(string alias, string contents, CancellationToken ct = default);
    Task StopAsync(string alias, CancellationToken ct = default);
    /// The caller's own tunnels (the service filters by user).
    Task<IReadOnlyList<TunnelRuntimeStatus>> StatusAsync(CancellationToken ct = default);
}

/// One pipe connection shared by the whole app. Calls are serialized (a pipe carries one
/// request at a time) and a dropped connection is reopened once, e.g. after a service restart.
public sealed class PipeTunnelService : ITunnelService, IAsyncDisposable
{
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(3);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ServiceClient? _client;

    public Task<string> HandshakeAsync(CancellationToken ct = default) =>
        CallAsync(async c => await c.CallAsync<string>(Ops.ServiceVersion, null, ct) ?? "0", ct);

    public Task StartAsync(string alias, string contents, CancellationToken ct = default) =>
        CallAsync(async c => { await c.CallAsync(Ops.StartTunnel, new StartTunnelArgs { Name = alias, Contents = contents }, ct); return true; }, ct);

    public Task StopAsync(string alias, CancellationToken ct = default) =>
        CallAsync(async c => { await c.CallAsync(Ops.StopTunnel, new TunnelNameArgs { Name = alias }, ct); return true; }, ct);

    public async Task<IReadOnlyList<TunnelRuntimeStatus>> StatusAsync(CancellationToken ct = default) =>
        await CallAsync(async c => await c.CallAsync<List<TunnelRuntimeStatus>>(Ops.RuntimeStatusSnapshot, null, ct) ?? [], ct);

    private async Task<T> CallAsync<T>(Func<ServiceClient, Task<T>> call, CancellationToken ct)
    {
        await _gate.WaitAsync(ct);
        try
        {
            for (var attempt = 0; ; attempt++)
            {
                _client ??= await ServiceClient.ConnectAsync(ConnectTimeout, ct);
                try
                {
                    return await call(_client);
                }
                catch (Exception e) when (e is IOException or ObjectDisposedException && attempt == 0)
                {
                    // The service restarted under us: reconnect and retry once. Requests are idempotent.
                    await DropAsync();
                }
                catch (IOException)
                {
                    await DropAsync();
                    throw new ServiceException("Lost the connection to the WireTunnels service.");
                }
            }
        }
        finally { _gate.Release(); }
    }

    private async Task DropAsync()
    {
        if (_client is { } client) await client.DisposeAsync();
        _client = null;
    }

    public async ValueTask DisposeAsync()
    {
        await _gate.WaitAsync();
        try { await DropAsync(); }
        finally { _gate.Release(); }
    }
}

public enum ServiceInstallState { Running, Stopped, Starting, NotInstalled, Unknown }

/// Whether the Windows service exists and runs, for the setup wizard.
public interface IServiceProbe
{
    ServiceInstallState Query();
}

[SupportedOSPlatform("windows")]
public sealed class WindowsServiceProbe : IServiceProbe
{
    public const string ServiceName = "WireTunnels";

    public ServiceInstallState Query()
    {
        try
        {
            using var controller = new ServiceController(ServiceName);
            return controller.Status switch
            {
                ServiceControllerStatus.Running => ServiceInstallState.Running,
                ServiceControllerStatus.StartPending or ServiceControllerStatus.ContinuePending => ServiceInstallState.Starting,
                _ => ServiceInstallState.Stopped,
            };
        }
        catch (InvalidOperationException)
        {
            return ServiceInstallState.NotInstalled;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return ServiceInstallState.Unknown;
        }
    }
}
