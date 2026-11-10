using System.IO.Pipes;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WireTunnels.Contracts;

public class ServiceException(string message) : Exception(message);

/// The service is reachable but speaks another protocol revision (app and service from different versions).
public sealed class ServiceProtocolException(string message) : ServiceException(message);

/// Client side of the service pipe, shared by the CLI and the app (the macOS WireGuardCommandService).
public sealed class ServiceClient : IAsyncDisposable
{
    private readonly NamedPipeClientStream _pipe;
    private int _nextId;

    private ServiceClient(NamedPipeClientStream pipe) => _pipe = pipe;

    /// Connects and refuses a service built for another protocol revision.
    public static async Task<ServiceClient> ConnectAsync(TimeSpan timeout, CancellationToken ct = default)
    {
        // Identification-level impersonation is all the service needs to read our SID.
        var pipe = new NamedPipeClientStream(".", Protocol.PipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous, TokenImpersonationLevel.Identification);
        try
        {
            await pipe.ConnectAsync(timeout, ct);
        }
        catch (TimeoutException)
        {
            await pipe.DisposeAsync();
            throw new ServiceException("The WireTunnels service is not running");
        }
        var client = new ServiceClient(pipe);
        string? revision;
        try
        {
            revision = await client.CallAsync<string>(Ops.ProtocolRevision, null, ct);
        }
        catch (Exception e) when (e is IOException or ServiceException)
        {
            // The service drops clients it does not trust before answering anything.
            await client.DisposeAsync();
            throw new ServiceException("The WireTunnels service refused the connection. Run WireTunnels from its install folder.");
        }
        if (revision != Protocol.Revision)
        {
            await client.DisposeAsync();
            throw new ServiceProtocolException($"The WireTunnels service speaks protocol {revision}, this app needs {Protocol.Revision}. Reinstall WireTunnels.");
        }
        return client;
    }

    public async Task<T?> CallAsync<T>(string op, object? args, CancellationToken ct = default)
    {
        var response = await SendAsync(new Request
        {
            Op = op,
            Args = args is null ? null : JsonSerializer.SerializeToNode(args, Protocol.Json)?.AsObject(),
        }, ct);
        if (!response.Ok) throw new ServiceException(response.Error ?? "The service reported an error");
        return response.Data is null ? default : response.Data.Deserialize<T>(Protocol.Json);
    }

    /// One raw round trip (the elevated helper relays requests as-is); errors stay in the response.
    public async Task<Response> SendAsync(Request request, CancellationToken ct = default)
    {
        request.Id = ++_nextId;
        await Protocol.WriteAsync(_pipe, request, ct);
        var response = await Protocol.ReadAsync<Response>(_pipe, ct) ?? throw new ServiceException("The service closed the connection");
        if (response.Id != request.Id) throw new ServiceException("Out-of-order response from the service");
        return response;
    }

    public Task CallAsync(string op, object? args, CancellationToken ct = default) => CallAsync<JsonNode>(op, args, ct);

    public ValueTask DisposeAsync() => _pipe.DisposeAsync();
}
