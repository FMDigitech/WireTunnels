using System.Text.Json;
using System.Text.Json.Nodes;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Service.WireGuard;

namespace WireTunnels.Service.Ipc;

/// Who is calling, taken from the pipe client's impersonation token (never from the request).
internal sealed record ClientIdentity(string Sid, string UserName, bool IsElevatedAdmin);

/// Validates and authorizes every request (the macOS HelperSession). A user can only start,
/// stop and see the tunnels they started; an elevated administrator can manage any of them.
internal sealed class RequestDispatcher(ITunnelBackend backend, ILogger<RequestDispatcher> log)
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<string, string> _owners = new(StringComparer.Ordinal);

    public static string Version => typeof(RequestDispatcher).Assembly.GetName().Version?.ToString() ?? "0";

    public async Task<Response> HandleAsync(Request request, ClientIdentity client, CancellationToken ct)
    {
        try
        {
            var data = request.Op switch
            {
                Ops.ProtocolRevision => JsonValue.Create(Protocol.Revision),
                Ops.ServiceVersion => JsonValue.Create(Version),
                Ops.StartTunnel => await StartAsync(Args<StartTunnelArgs>(request), client, ct),
                Ops.StopTunnel => await StopAsync(Args<TunnelNameArgs>(request), client),
                Ops.RuntimeStatusSnapshot => await StatusAsync(client),
                _ => throw new RequestException($"Unknown operation: {request.Op}"),
            };
            return new Response { Id = request.Id, Ok = true, Data = data };
        }
        catch (RequestException e)
        {
            return new Response { Id = request.Id, Error = e.Message };
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            log.LogError(e, "{Op} failed for {User}", request.Op, client.UserName);
            return new Response { Id = request.Id, Error = e.Message };
        }
    }

    private async Task<JsonNode?> StartAsync(StartTunnelArgs args, ClientIdentity client, CancellationToken ct)
    {
        var alias = ValidAlias(args.Name);
        var config = WireGuardConfig.Parse(args.Contents);
        if (!config.IsValid) throw new RequestException(string.Join("; ", config.Errors.Select(e => e.Message)));

        await _gate.WaitAsync(ct);
        try
        {
            if (backend.IsRunning(alias))
            {
                // Same tolerance as wg-quick's "already exists": reconnecting your own tunnel is a no-op.
                if (_owners.GetValueOrDefault(alias) == client.Sid) return null;
                throw new RequestException($"A tunnel named {alias} is already connected by another user");
            }
            await backend.StartAsync(alias, config, ct);
            _owners[alias] = client.Sid;
            log.LogInformation("{User} connected {Alias}", client.UserName, alias);
            return null;
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> StopAsync(TunnelNameArgs args, ClientIdentity client)
    {
        var alias = ValidAlias(args.Name);
        await _gate.WaitAsync();
        try
        {
            if (!backend.IsRunning(alias)) return null;
            if (!client.IsElevatedAdmin && _owners.GetValueOrDefault(alias) != client.Sid)
                throw new RequestException($"{alias} was connected by another user");
            backend.Stop(alias);
            _owners.Remove(alias);
            log.LogInformation("{User} disconnected {Alias}", client.UserName, alias);
            return null;
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> StatusAsync(ClientIdentity client)
    {
        await _gate.WaitAsync();
        try
        {
            var visible = _owners.Where(o => client.IsElevatedAdmin || o.Value == client.Sid).Select(o => o.Key);
            return JsonSerializer.SerializeToNode(visible.Select(backend.Status).ToList(), Protocol.Json);
        }
        finally { _gate.Release(); }
    }

    private static string ValidAlias(string name) =>
        ConfigName.IsValidAlias(name) ? name : throw new RequestException("Invalid tunnel name");

    private static T Args<T>(Request request) where T : class
    {
        try
        {
            return request.Args?.Deserialize<T>(Protocol.Json) ?? throw new RequestException("Missing arguments");
        }
        catch (JsonException)
        {
            throw new RequestException("Invalid arguments");
        }
    }
}

/// An expected rejection: its message goes back to the client as-is.
internal sealed class RequestException(string message) : Exception(message);
