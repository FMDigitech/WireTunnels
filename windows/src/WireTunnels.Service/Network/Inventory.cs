using System.Net;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Net;
using WireTunnels.Service.Ipc;
using WireTunnels.Service.WireGuard;

namespace WireTunnels.Service.Network;

/// One inventory policy as the service keeps it (port of InventoryRoutingService.Record).
internal sealed class InventoryRecord
{
    public Guid OwnerId { get; set; }
    /// Who owns it: only that Windows user can change or remove it.
    public string Sid { get; set; } = "";
    public Guid Generation { get; set; }
    public string Name { get; set; } = "";
    public string LocalPublicKey { get; set; } = "";
    public string PeerPublicKey { get; set; } = "";
    public List<string> StaticPrefixes { get; set; } = [];
    public List<string> DiscoveredPrefixes { get; set; } = [];
    /// Prefixes of an update in progress: blocked too until it completes.
    public List<string>? PendingPrefixes { get; set; }
    /// The tunnel adapter that may carry the destinations; null while protected (blocked everywhere).
    public ulong? AllowedLuid { get; set; }
    /// Routes added for discovered prefixes, on AllowedLuid.
    public List<InstalledRoute> OwnedRoutes { get; set; } = [];
    public string? EndpointHost { get; set; }
    public int EndpointPort { get; set; }

    public IReadOnlyList<string> Guarded() =>
        IPPrefix.Normalized([.. StaticPrefixes, .. DiscoveredPrefixes, .. PendingPrefixes ?? []], 200_000);

    public InventoryRecord Copy() => JsonSerializer.Deserialize<InventoryRecord>(JsonSerializer.Serialize(this, Protocol.Json), Protocol.Json)!;
}

/// Where the policies live; faked in tests.
internal interface IInventoryStore
{
    List<InventoryRecord> Load();
    void Save(IReadOnlyList<InventoryRecord> records);
}

/// Inventory AllowedIPs on Windows (port of InventoryRoutingService). Policies are persistent: their WFP
/// filters survive reboots and service stops, and every policy is restored as blocked when the service starts.
/// Callers serialize the calls (RequestDispatcher's gate) and check that an apply targets the caller's tunnel.
internal sealed class InventoryPolicy(ITunnelBackend backend, IFirewall firewall, IRouteTable routes, IInventoryStore store,
    ILogger<InventoryPolicy> log)
{
    private List<InventoryRecord> _records = [];

    public IReadOnlyList<InventoryRecord> Records => _records;

    /// Service start: no adapter exists yet, so every policy blocks everywhere.
    public void Restore()
    {
        _records = store.Load();
        foreach (var record in _records)
        {
            record.AllowedLuid = null;
            record.OwnedRoutes = [];
        }
        Install(_records);
        store.Save(_records);
        if (_records.Count > 0) log.LogInformation("Restored {Count} inventory protection policies", _records.Count);
    }

    /// The tunnel's adapter is gone (stopped or lost): its destinations are blocked again.
    public void TunnelStopped(string alias)
    {
        var changed = false;
        foreach (var record in _records.Where(r => r.Name == alias && (r.AllowedLuid is not null || r.OwnedRoutes.Count > 0)))
        {
            record.AllowedLuid = null;
            record.OwnedRoutes = []; // removed with the adapter
            changed = true;
        }
        if (!changed) return;
        Install(_records);
        store.Save(_records);
    }

    public void Perform(InventoryRoutingRequest request, string sid)
    {
        var old = _records.FirstOrDefault(r => r.OwnerId == request.OwnerId);
        if (old is not null && old.Sid != sid) throw new RequestException("Inventory policy belongs to another user");
        var others = _records.Where(r => r.OwnerId != request.OwnerId).ToList();

        if (request.Action == InventoryAction.Remove)
        {
            if (old is null) return;
            RemoveRoutes(old, old.OwnedRoutes);
            Commit(others);
            return;
        }

        if (!ConfigName.IsValidAlias(request.Name) || WireGuardKey.Decode(request.LocalPublicKey) is null || WireGuardKey.Decode(request.PeerPublicKey) is null)
            throw new RequestException(IPPrefix.InventoryOutputMessage);
        IReadOnlyList<string> staticPrefixes, discovered;
        try
        {
            staticPrefixes = IPPrefix.Normalized(request.StaticPrefixes);
            discovered = IPPrefix.InventoryPrefixes(request.DiscoveredPrefixes);
        }
        catch (FormatException e) { throw new RequestException(e.Message); }
        if (staticPrefixes.Count == 0) throw new RequestException(IPPrefix.InventoryOutputMessage);
        if (request.Action == InventoryAction.Apply && old?.Generation != request.Generation)
            throw new RequestException("The tunnel changed while its inventory was being refreshed.");
        if ((request.Action == InventoryAction.Protect || request.UseCachedInventory) && old is not null) discovered = old.DiscoveredPrefixes;

        var effective = IPPrefix.Normalized([.. staticPrefixes, .. discovered]);
        var protectedIndex = new IPPrefixIndex(effective.Select(IPPrefix.Parse));
        foreach (var other in others)
            if (other.Guarded().Select(IPPrefix.Parse).Any(protectedIndex.Overlaps))
                throw new RequestException("Inventory-protected destinations cannot overlap another inventory tunnel");

        var endpoint = request.EndpointHost is { } host && IPPrefix.IsValidAddress(host) && request.EndpointPort is >= 1 and <= 65535
            ? (host, request.EndpointPort) : (old?.EndpointHost, old?.EndpointPort ?? 0);
        var record = new InventoryRecord
        {
            OwnerId = request.OwnerId, Sid = sid, Generation = request.Generation, Name = request.Name,
            LocalPublicKey = request.LocalPublicKey, PeerPublicKey = request.PeerPublicKey,
            StaticPrefixes = [.. staticPrefixes], DiscoveredPrefixes = [.. discovered],
            EndpointHost = endpoint.Item1, EndpointPort = endpoint.Item2,
        };

        if (request.Action == InventoryAction.Protect)
        {
            // Block first, then drop the old exception's routes.
            Commit([.. others, record]);
            if (old is not null) RemoveRoutes(old, old.OwnedRoutes);
            return;
        }
        Apply(old!, record, others, effective);
    }

    /// Lets the destinations through the verified tunnel only, after its routes and AllowedIPs are in place.
    private void Apply(InventoryRecord old, InventoryRecord record, List<InventoryRecord> others, IReadOnlyList<string> effective)
    {
        // The tunnel must still be the one the app connected: same adapter alias, same keys.
        if (backend.Luid(record.Name) is not { } luid) throw new RequestException("The tunnel changed while its inventory was being refreshed.");
        var status = backend.Status(record.Name);
        if (status.PublicKey != record.LocalPublicKey || status.Peers.All(p => p.PublicKey != record.PeerPublicKey))
            throw new RequestException("The tunnel changed while its inventory was being refreshed.");
        if (status.Peers.First(p => p.PublicKey == record.PeerPublicKey).Endpoint is { } live && Endpoint.TryParse(live) is { } ep)
            (record.EndpointHost, record.EndpointPort) = (ep.Host, ep.Port);

        var owned = old.AllowedLuid == luid ? old.OwnedRoutes : [];
        var staticIndex = new IPPrefixIndex(record.StaticPrefixes.Select(IPPrefix.Parse));
        // Static prefixes already have routes from the tunnel itself.
        var wanted = record.DiscoveredPrefixes.Where(p => !staticIndex.Contains(IPPrefix.Parse(p))).ToHashSet();
        var ownedCidrs = owned.Select(r => r.Cidr).ToHashSet();
        if (old.AllowedLuid == luid && old.PendingPrefixes is null && wanted.SetEquals(ownedCidrs)
            && old.StaticPrefixes.SequenceEqual(record.StaticPrefixes) && old.DiscoveredPrefixes.SequenceEqual(record.DiscoveredPrefixes))
            return;

        // While routes and AllowedIPs change, the new destinations are blocked everywhere; the old ones keep their
        // verified path (a refresh must not cut working connections).
        var transition = old.Copy();
        transition.PendingPrefixes = [.. effective];
        if (old.AllowedLuid != luid) transition.AllowedLuid = null;
        Commit([.. others, transition]);

        var installed = owned.ToList();
        var peerChanged = false;
        try
        {
            foreach (var cidr in wanted.Except(ownedCidrs).Order())
                installed.Add(routes.Add(IPPrefix.Parse(cidr), luid, backend.Luids));
            peerChanged = true;
            backend.SetPeerAllowedIPs(record.Name, record.PeerPublicKey, effective.Select(IPPrefix.Parse).ToList());
            foreach (var stale in owned.Where(r => !wanted.Contains(r.Cidr)).ToList())
            {
                routes.Delete(stale);
                installed.Remove(stale);
            }
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
        {
            // shortcut: fail closed instead of macOS's fine-grained rollback; the tunnel's destinations stay blocked
            // until it reconnects. Upgrade if refresh failures turn out to be common.
            if (peerChanged)
            {
                try { backend.SetPeerAllowedIPs(record.Name, old.PeerPublicKey, IPPrefix.Normalized([.. old.StaticPrefixes, .. old.DiscoveredPrefixes]).Select(IPPrefix.Parse).ToList()); }
                catch (Exception rollback) when (rollback is System.ComponentModel.Win32Exception or InvalidOperationException) { log.LogWarning(rollback, "Unable to restore AllowedIPs of {Name}", record.Name); }
            }
            transition.AllowedLuid = null;
            transition.OwnedRoutes = installed;
            Commit([.. others, transition]);
            log.LogError(e, "Inventory update of {Name} failed", record.Name);
            throw new RequestException("Inventory update failed; destinations remain blocked until the tunnel reconnects");
        }
        record.AllowedLuid = luid;
        record.OwnedRoutes = installed;
        Commit([.. others, record]);
    }

    private void RemoveRoutes(InventoryRecord record, IEnumerable<InstalledRoute> owned)
    {
        // Routes of a vanished adapter went with it; never touch a route on a replacement adapter.
        if (record.AllowedLuid is not { } luid || backend.Luid(record.Name) != luid) return;
        foreach (var route in owned.ToList())
        {
            try { routes.Delete(route); }
            catch (System.ComponentModel.Win32Exception e) { log.LogWarning(e, "Unable to remove inventory route {Cidr}", route.Cidr); }
        }
    }

    /// Filters first, then the file: a crash in between leaves at worst more blocked, never less.
    private void Commit(List<InventoryRecord> records)
    {
        Install(records);
        store.Save(records);
        _records = records;
    }

    private void Install(IReadOnlyList<InventoryRecord> records) =>
        firewall.SetInventoryGuards(records.Select(r => new InventoryGuard(
            r.Guarded().Select(IPPrefix.Parse).ToList(),
            r.AllowedLuid,
            r.EndpointHost is { } h && IPPrefix.TryParseAddress(h, out var ip) ? new IPEndPoint(ip, r.EndpointPort) : null)).ToList());
}

/// %ProgramData%\WireTunnels\inventory.json in a folder only SYSTEM and Administrators can open.
[SupportedOSPlatform("windows")]
internal sealed class ProgramDataInventoryStore : IInventoryStore
{
    private static readonly SecurityIdentifier LocalSystem = new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier Administrators = new(WellKnownSidType.BuiltinAdministratorsSid, null);

    private readonly string _directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WireTunnels");
    private string PolicyFile => Path.Combine(_directory, "inventory.json");

    public List<InventoryRecord> Load()
    {
        if (!File.Exists(PolicyFile)) return [];
        EnsureSecureDirectory();
        return JsonSerializer.Deserialize<List<InventoryRecord>>(File.ReadAllText(PolicyFile), Protocol.Json) ?? [];
    }

    public void Save(IReadOnlyList<InventoryRecord> records)
    {
        EnsureSecureDirectory();
        var temp = PolicyFile + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(records, Protocol.Json));
        File.Move(temp, PolicyFile, overwrite: true);
    }

    /// ProgramData lets any user create folders: a WireTunnels folder someone else created is refused,
    /// and ours always gets a protected ACL (no inheritance from ProgramData).
    private void EnsureSecureDirectory()
    {
        var security = new DirectorySecurity();
        security.SetOwner(Administrators);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { LocalSystem, Administrators })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        var info = new DirectoryInfo(_directory);
        if (!info.Exists)
        {
            info.Create(security);
            return;
        }
        var owner = info.GetAccessControl().GetOwner(typeof(SecurityIdentifier));
        if (owner != LocalSystem && owner != Administrators)
            throw new UnauthorizedAccessException($"{_directory} is owned by another account; remove it so the service can recreate it");
        info.SetAccessControl(security);
    }
}
