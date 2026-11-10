using System.Text.Json;
using System.Text.Json.Nodes;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;
using WireTunnels.Service.Managed;
using WireTunnels.Service.Network;
using WireTunnels.Service.WireGuard;

namespace WireTunnels.Service.Ipc;

/// Who is calling, taken from the pipe client's impersonation token (never from the request).
/// SessionId is the client's Windows logon session (-1 when unknown, e.g. in tests).
internal sealed record ClientIdentity(string Sid, string UserName, bool IsElevatedAdmin, int SessionId = -1);

/// Validates and authorizes every request (the macOS HelperSession). A user can only start,
/// stop and see the tunnels they started; an elevated administrator can manage any of them.
/// Shared tunnels are in RequestDispatcher.Managed.cs.
internal sealed partial class RequestDispatcher(ITunnelBackend backend, NetworkPolicy network, InventoryPolicy inventory, IManagedStore managed,
    ILogger<RequestDispatcher> log)
{
    private const int MaxKillSwitchEntries = 64, MaxSplitDnsEntries = 64, MaxRouteEntries = 1024;

    private readonly SemaphoreSlim _gate = new(1, 1);
    /// Running alias -> owner SID, or ManagedOwnerPrefix + id for a shared tunnel.
    private readonly Dictionary<string, string> _owners = new(StringComparer.Ordinal);
    /// Logon sessions each user has talked to us from (for SessionLoggedOffAsync).
    private readonly Dictionary<string, HashSet<int>> _sessions = new(StringComparer.Ordinal);

    public static string Version => typeof(RequestDispatcher).Assembly.GetName().Version?.ToString() ?? "0";

    public async Task<Response> HandleAsync(Request request, ClientIdentity client, CancellationToken ct)
    {
        if (client.SessionId >= 0)
            lock (_sessions)
                (_sessions.TryGetValue(client.Sid, out var known) ? known : _sessions[client.Sid] = []).Add(client.SessionId);
        try
        {
            var data = request.Op switch
            {
                Ops.ProtocolRevision => JsonValue.Create(Protocol.Revision),
                Ops.ServiceVersion => JsonValue.Create(Version),
                Ops.StartTunnel => await StartAsync(Args<StartTunnelArgs>(request), client, ct),
                Ops.StopTunnel => await StopAsync(Args<TunnelNameArgs>(request), client),
                Ops.RuntimeStatusSnapshot => await StatusAsync(client),
                Ops.SyncKillSwitch => await SyncKillSwitchAsync(Args<SyncKillSwitchArgs>(request), client),
                Ops.SyncSplitDns => await SyncSplitDnsAsync(Args<SyncSplitDnsArgs>(request), client),
                Ops.SyncRoutes => await SyncRoutesAsync(Args<SyncRoutesArgs>(request), client),
                Ops.UpdateInventoryRouting => await UpdateInventoryAsync(Args<InventoryRoutingRequest>(request), client),
                Ops.ListManaged => ListManaged(),
                Ops.StartManaged => await StartManagedAsync(Args<ManagedIdArgs>(request), client, ct),
                Ops.GetSystemSettings => JsonSerializer.SerializeToNode(managed.LoadSettings(), Protocol.Json),
                Ops.ReadManaged => ReadManaged(Args<ManagedIdArgs>(request), client),
                Ops.InstallManaged => await InstallManagedAsync(Args<InstallManagedArgs>(request), client),
                Ops.UpdateManaged => await UpdateManagedAsync(Args<UpdateManagedArgs>(request), client),
                Ops.DeleteManaged => await DeleteManagedAsync(Args<ManagedIdArgs>(request), client),
                Ops.ListManagedUsers => await ListManagedUsersAsync(Args<ManagedIdArgs>(request), client),
                Ops.SetSystemSettings => SetSystemSettings(Args<SystemSettings>(request), client),
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
            // A personal tunnel must not take a shared tunnel's adapter name (macOS stageConfig).
            if (ManagedRecordForAlias(alias) is not null) throw new RequestException("A shared tunnel already uses this name");
            if (backend.IsRunning(alias))
            {
                // Same tolerance as wg-quick's "already exists": reconnecting your own tunnel is a no-op.
                if (_owners.GetValueOrDefault(alias) == client.Sid) return null;
                throw new RequestException($"A tunnel named {alias} is already connected by another user");
            }
            await backend.StartAsync(alias, config, args.SuppressDns, ct);
            _owners[alias] = client.Sid;
            RefreshKillSwitch();
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
            var owner = _owners.GetValueOrDefault(alias);
            if (IsManagedOwner(owner)) AuthorizeManagedStop(alias, client);
            else if (!client.IsElevatedAdmin && owner != client.Sid)
                throw new RequestException($"{alias} was connected by another user");
            StopRunning(alias);
            log.LogInformation("{User} disconnected {Alias}", client.UserName, alias);
            return null;
        }
        finally { _gate.Release(); }
    }

    /// Callers hold the gate. A shared tunnel stops for everyone.
    private void StopRunning(string alias)
    {
        backend.Stop(alias);
        if (_owners.Remove(alias, out var owner) && IsManagedOwner(owner))
        {
            var id = Guid.Parse(owner[ManagedOwnerPrefix.Length..]);
            _managedSessions.Remove(id);
            if (managed.Load().FirstOrDefault(r => r.Id == id) is { } record) SyncManagedSplitDns(record, stopped: true);
        }
        network.ForgetTunnel(alias);
        inventory.TunnelStopped(alias);
        RefreshKillSwitch();
    }

    /// SERVICE_CONTROL_SESSIONCHANGE logoff: when a user's last known session ends, their personal tunnels stop and
    /// their kill switch, split DNS and routes go, so the next user of the PC is neither tunneled nor blocked.
    /// Running shared tunnels stop too when their policy lets users disconnect: on macOS the app quits at logout and
    /// its quit disconnects every tunnel. shortcut: a user only counts as logged on in sessions their app or CLI talked
    /// to the service from; a user who never ran WireTunnels in another open session loses their tunnels on this logoff.
    public async Task SessionLoggedOffAsync(int sessionId)
    {
        List<string> gone = [];
        lock (_sessions)
        {
            foreach (var (sid, known) in _sessions)
                if (known.Remove(sessionId) && known.Count == 0) gone.Add(sid);
            foreach (var sid in gone) _sessions.Remove(sid);
        }
        if (gone.Count == 0) return;
        await _gate.WaitAsync();
        try
        {
            foreach (var sid in gone)
            {
                foreach (var alias in _owners.Where(o => o.Value == sid).Select(o => o.Key).ToList()) StopRunning(alias);
                foreach (var alias in _owners.Where(o => IsManagedOwner(o.Value)).Select(o => o.Key).ToList())
                    if (ManagedRecordForAlias(alias)?.ManagedPolicy is not { UsersCanDisconnect: false }) StopRunning(alias);
                foreach (var sessions in _managedSessions.Values) sessions.RemoveAll(s => s.Sid == sid);
                network.ForgetUser(sid);
                log.LogInformation("Session {Session} logged off: stopped the tunnels and network policy of {Sid}", sessionId, sid);
            }
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException or RequestException)
        {
            log.LogError(e, "Unable to clean up after the logoff of session {Session}", sessionId);
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> StatusAsync(ClientIdentity client)
    {
        await _gate.WaitAsync();
        try
        {
            var visible = _owners.Where(o => client.IsElevatedAdmin || o.Value == client.Sid || IsManagedOwner(o.Value)).Select(o => o.Key);
            return JsonSerializer.SerializeToNode(visible.Select(backend.Status).ToList(), Protocol.Json);
        }
        finally { _gate.Release(); }
    }

    /// The armed tunnels' adapters changed: re-resolve their permits (a failure keeps the old filters, which still block).
    private void RefreshKillSwitch()
    {
        if (!network.KillSwitchArmed) return;
        try { network.ApplyKillSwitch(); }
        catch (System.ComponentModel.Win32Exception e) { log.LogError(e, "Unable to update the kill switch"); }
    }

    private async Task<JsonNode?> SyncKillSwitchAsync(SyncKillSwitchArgs args, ClientIdentity client)
    {
        if (args.Entries.Count > MaxKillSwitchEntries) throw new RequestException("Too many kill switch entries");
        foreach (var entry in args.Entries)
        {
            ValidAlias(entry.Name);
            if (!IPPrefix.IsValidAddress(entry.EndpointHost)) throw new RequestException("Invalid kill switch endpoint");
            if (entry.EndpointPort is < 1 or > 65535) throw new RequestException("Invalid kill switch endpoint port");
        }
        await _gate.WaitAsync();
        try
        {
            // A running tunnel can only be armed by whoever started it (any user for a shared one); a stopped one blocks for its owner.
            if (args.Entries.FirstOrDefault(e => backend.IsRunning(e.Name) && _owners.GetValueOrDefault(e.Name) is var o && o != client.Sid && !IsManagedOwner(o)) is { } foreign)
                throw new RequestException($"{foreign.Name} was connected by another user");
            network.SyncKillSwitch(client.Sid, args.Entries);
            return null;
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> SyncSplitDnsAsync(SyncSplitDnsArgs args, ClientIdentity client)
    {
        if (args.Entries.Count > MaxSplitDnsEntries) throw new RequestException("Too many split DNS entries");
        var desired = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal);
        foreach (var entry in args.Entries)
        {
            if (entry.Domains.Count is < 1 or > 32 || entry.Servers.Count is < 1 or > 8) throw new RequestException("Invalid split DNS entry");
            if (entry.Domains.FirstOrDefault(d => !SplitDns.IsValidDomain(d)) is { } domain) throw new RequestException($"Invalid split DNS domain: {domain}");
            if (entry.Servers.FirstOrDefault(s => !IPPrefix.IsValidAddress(s)) is { } server) throw new RequestException($"Invalid split DNS server: {server}");
            foreach (var d in entry.Domains) desired.TryAdd(d, entry.Servers);
        }
        await _gate.WaitAsync();
        try
        {
            var conflicts = network.SyncSplitDns(client.Sid, desired);
            if (conflicts.Count > 0)
                throw new RequestException($"Existing DNS rules for {string.Join(", ", conflicts.Order())} were left untouched");
            return null;
        }
        catch (InvalidOperationException e) { throw new RequestException(e.Message); }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> SyncRoutesAsync(SyncRoutesArgs args, ClientIdentity client)
    {
        if (args.OwnerId == Guid.Empty) throw new RequestException("Invalid route owner");
        if (args.Entries.Count > MaxRouteEntries) throw new RequestException("Too many routes");
        foreach (var entry in args.Entries)
        {
            if (!IPPrefix.IsValidCidr(entry.Cidr)) throw new RequestException($"Invalid route CIDR: {entry.Cidr}");
            if (entry.Tunnel is { } alias) ValidAlias(alias);
        }
        await _gate.WaitAsync();
        try
        {
            if (args.Entries.FirstOrDefault(e => e.Tunnel is { } t && _owners.GetValueOrDefault(t) != client.Sid) is { } foreign)
                throw new RequestException($"{foreign.Tunnel} is not one of your connected tunnels");
            network.SyncRoutes(client.Sid, args.OwnerId, args.Entries.Select(e => e with { Cidr = IPPrefix.Parse(e.Cidr).ToString() }).ToList());
            return null;
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> UpdateInventoryAsync(InventoryRoutingRequest args, ClientIdentity client)
    {
        if (args.OwnerId == Guid.Empty) throw new RequestException("Invalid inventory owner");
        await _gate.WaitAsync();
        try
        {
            // Apply opens the destinations through a tunnel: only through one the caller connected.
            if (args.Action == InventoryAction.Apply && (!backend.IsRunning(ValidAlias(args.Name)) || _owners.GetValueOrDefault(args.Name) != client.Sid))
                throw new RequestException("The tunnel changed while its inventory was being refreshed.");
            inventory.Perform(args, client.Sid);
            return null;
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
