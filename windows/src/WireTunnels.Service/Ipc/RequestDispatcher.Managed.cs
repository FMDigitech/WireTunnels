using System.Text.Json;
using System.Text.Json.Nodes;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Service.Network;

namespace WireTunnels.Service.Ipc;

/// Shared (managed) tunnels, port of the HelperTool managed ops. A shared tunnel is machine-wide: once up it is
/// up for everyone, every user sees it, and it survives the logoff of whoever connected it. Its config stays in
/// the service: users start it by id, only an elevated administrator can read or change it.
internal sealed partial class RequestDispatcher
{
    private const string ManagedOwnerPrefix = "managed:";
    private const int MaxConfigBytes = 256 * 1024, MaxSplitDnsDomains = 32;

    /// Who connected each running shared tunnel (runtime only: the adapters do not outlive the service either).
    private readonly Dictionary<Guid, List<ManagedTunnelUserSession>> _managedSessions = [];

    private static bool IsManagedOwner(string? owner) => owner?.StartsWith(ManagedOwnerPrefix, StringComparison.Ordinal) == true;

    private Tunnel? ManagedRecordForAlias(string alias) => managed.Load().FirstOrDefault(r => r.ConfigPath == alias);

    private JsonNode? ListManaged()
    {
        // Sanitized by construction: a record holds public keys and addresses, never the config.
        return JsonSerializer.SerializeToNode(managed.Load(), Protocol.Json);
    }

    private async Task<JsonNode?> StartManagedAsync(ManagedIdArgs args, ClientIdentity client, CancellationToken ct)
    {
        await _gate.WaitAsync(ct);
        try
        {
            var record = FindManaged(args.Id);
            var policy = record.ManagedPolicy ?? new();
            if (!policy.UsersCanConnect && !client.IsElevatedAdmin) throw new RequestException("Users are not allowed to connect this shared tunnel");
            var alias = record.ConfigPath;
            if (backend.IsRunning(alias))
            {
                if (_owners.GetValueOrDefault(alias) != ManagedOwnerPrefix + record.Id)
                    throw new RequestException($"A tunnel named {alias} is already connected by another user");
            }
            else
            {
                var config = WireGuardConfig.Parse(managed.ReadConfig(record.Id));
                if (!config.IsValid) throw new RequestException(string.Join("; ", config.Errors.Select(e => e.Message)));
                // Split DNS replaces the adapter's DNS with NRPT rules (macOS strips DNS from the staged config).
                await backend.StartAsync(alias, config, suppressDns: policy.SplitDNSDomains.Count > 0, ct);
                _owners[alias] = ManagedOwnerPrefix + record.Id;
                _managedSessions.Remove(record.Id);
                RefreshKillSwitch();
                SyncManagedSplitDns(record);
                log.LogInformation("{User} connected shared tunnel {Alias}", client.UserName, alias);
            }
            var sessions = _managedSessions.TryGetValue(record.Id, out var list) ? list : _managedSessions[record.Id] = [];
            sessions.RemoveAll(s => s.Sid == client.Sid);
            sessions.Add(new ManagedTunnelUserSession { Sid = client.Sid, Username = client.UserName, ConnectedAt = DateTimeOffset.UtcNow });
            return null;
        }
        finally { _gate.Release(); }
    }

    /// StopAsync's policy check for a running shared tunnel.
    private void AuthorizeManagedStop(string alias, ClientIdentity client)
    {
        if (client.IsElevatedAdmin) return;
        if (ManagedRecordForAlias(alias)?.ManagedPolicy is { UsersCanDisconnect: false })
            throw new RequestException("Users are not allowed to disconnect this shared tunnel");
    }

    private JsonNode? ReadManaged(ManagedIdArgs args, ClientIdentity client)
    {
        RequireAdmin(client);
        return JsonValue.Create(managed.ReadConfig(FindManaged(args.Id).Id));
    }

    private async Task<JsonNode?> InstallManagedAsync(InstallManagedArgs args, ClientIdentity client)
    {
        RequireAdmin(client);
        var (name, alias) = ValidManagedName(args.Name);
        var config = ValidManagedConfig(args.Contents);
        await _gate.WaitAsync();
        try
        {
            var records = managed.Load();
            if (records.Any(r => r.ConfigPath == alias || r.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
                throw new RequestException($"A shared tunnel named {name} already exists");
            var now = DateTimeOffset.UtcNow;
            var record = new Tunnel { Name = name, ConfigPath = alias, Scope = TunnelScope.Managed, ManagedPolicy = new(), CreatedAt = now, UpdatedAt = now };
            ApplyMetadata(record, config);
            managed.WriteConfig(record.Id, args.Contents);
            try { managed.Save([.. records, record]); }
            catch
            {
                managed.DeleteConfig(record.Id);
                throw;
            }
            log.LogInformation("{User} installed shared tunnel {Name}", client.UserName, name);
            return JsonSerializer.SerializeToNode(record, Protocol.Json);
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> UpdateManagedAsync(UpdateManagedArgs args, ClientIdentity client)
    {
        RequireAdmin(client);
        var (name, alias) = ValidManagedName(args.Name);
        var config = args.Contents is { } contents ? ValidManagedConfig(contents) : null;
        var domains = args.Policy.SplitDNSDomains;
        if (domains.Count > MaxSplitDnsDomains) throw new RequestException("Too many split DNS domains");
        if (domains.FirstOrDefault(d => !SplitDns.IsValidDomain(d)) is { } domain) throw new RequestException($"Invalid split DNS domain: {domain}");
        await _gate.WaitAsync();
        try
        {
            var records = managed.Load();
            var record = records.FirstOrDefault(r => r.Id == args.Id) ?? throw new RequestException("Shared tunnel not found");
            if (records.Any(r => r.Id != record.Id && (r.ConfigPath == alias || r.Name.Equals(name, StringComparison.OrdinalIgnoreCase))))
                throw new RequestException($"A shared tunnel named {name} already exists");
            // The running adapter is named after the old alias and runs the old config.
            if ((alias != record.ConfigPath || config is not null) && backend.IsRunning(record.ConfigPath))
                throw new RequestException("Disconnect the shared tunnel before changing its name or configuration");
            record.Name = name;
            record.ConfigPath = alias;
            record.ManagedPolicy = args.Policy;
            record.AutoConnectRule = args.AutoConnectRule;
            record.UpdatedAt = DateTimeOffset.UtcNow;
            if (config is not null)
            {
                ApplyMetadata(record, config);
                managed.WriteConfig(record.Id, args.Contents!);
            }
            managed.Save(records);
            if (backend.IsRunning(record.ConfigPath)) SyncManagedSplitDns(record);
            log.LogInformation("{User} updated shared tunnel {Name}", client.UserName, name);
            return null;
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> DeleteManagedAsync(ManagedIdArgs args, ClientIdentity client)
    {
        RequireAdmin(client);
        await _gate.WaitAsync();
        try
        {
            var records = managed.Load();
            var record = records.FirstOrDefault(r => r.Id == args.Id) ?? throw new RequestException("Shared tunnel not found");
            if (backend.IsRunning(record.ConfigPath)) throw new RequestException("Disconnect the shared tunnel before deleting it");
            managed.Save(records.Where(r => r.Id != record.Id).ToList());
            managed.DeleteConfig(record.Id);
            _managedSessions.Remove(record.Id);
            log.LogInformation("{User} deleted shared tunnel {Name}", client.UserName, record.Name);
            return null;
        }
        finally { _gate.Release(); }
    }

    private async Task<JsonNode?> ListManagedUsersAsync(ManagedIdArgs args, ClientIdentity client)
    {
        RequireAdmin(client);
        await _gate.WaitAsync();
        try
        {
            var record = FindManaged(args.Id);
            var sessions = backend.IsRunning(record.ConfigPath) ? _managedSessions.GetValueOrDefault(record.Id) ?? [] : [];
            return JsonSerializer.SerializeToNode(sessions.OrderBy(s => s.Username, StringComparer.OrdinalIgnoreCase).ToList(), Protocol.Json);
        }
        finally { _gate.Release(); }
    }

    private JsonNode? SetSystemSettings(SystemSettings settings, ClientIdentity client)
    {
        RequireAdmin(client);
        managed.SaveSettings(settings);
        return null;
    }

    /// One set of NRPT rules per running shared tunnel, owned by the service rather than by each user's app
    /// (two users' apps syncing the same domains would conflict). `stopped` removes them.
    private void SyncManagedSplitDns(Tunnel record, bool stopped = false)
    {
        var servers = WireGuardDns.Servers(record.Dns).ToList();
        List<string> domains = stopped || servers.Count == 0 ? [] : record.ManagedPolicy?.SplitDNSDomains ?? [];
        try
        {
            var conflicts = network.SyncSplitDns(ManagedOwnerPrefix + record.Id, domains.Distinct().ToDictionary(d => d, _ => (IReadOnlyList<string>)servers));
            if (conflicts.Count > 0) log.LogWarning("Shared tunnel {Name}: existing DNS rules for {Domains} were left untouched", record.Name, string.Join(", ", conflicts));
        }
        catch (InvalidOperationException e) { log.LogError(e, "Shared tunnel {Name}: split DNS could not be applied", record.Name); }
    }

    private Tunnel FindManaged(Guid id) =>
        managed.Load().FirstOrDefault(r => r.Id == id) ?? throw new RequestException("Shared tunnel not found");

    private static void RequireAdmin(ClientIdentity client)
    {
        if (!client.IsElevatedAdmin) throw new RequestException("Only an administrator can change shared tunnels. Approve the administrator prompt to continue.");
    }

    private static (string Name, string Alias) ValidManagedName(string raw)
    {
        var name = ConfigName.DisplayName(raw);
        if (name.Length == 0 || name.Any(char.IsControl)) throw new RequestException("Invalid tunnel name");
        return (name, ConfigName.FileBaseName(name));
    }

    private static WireGuardConfig ValidManagedConfig(string contents)
    {
        if (contents.Length > MaxConfigBytes) throw new RequestException("The configuration is too large");
        var config = WireGuardConfig.Parse(contents);
        return config.IsValid ? config : throw new RequestException(string.Join("; ", config.Errors.Select(e => e.Message)));
    }

    /// Port of sanitizedMetadata: what users may see of the config.
    private static void ApplyMetadata(Tunnel record, WireGuardConfig config)
    {
        var peer = config.PrimaryPeer;
        record.Address = [.. config.Address];
        record.AllowedIPs = [.. peer?.AllowedIPs ?? []];
        record.Dns = [.. config.Dns];
        record.Endpoint = peer?.Endpoint;
        record.PublicKey = peer?.PublicKey;
        record.LocalPublicKey = config.PrivateKey is { } key ? WireGuardKey.PublicKey(key) : null;
    }
}
