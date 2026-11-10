using System.Net;
using System.Text;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
using WireTunnels.Core.Net;
using WireTunnels.Core.Storage;

namespace WireTunnels.Client.Tests;

/// The service as seen through the pipe: adapters by alias, with scripted failures.
internal sealed class FakeTunnelService : ITunnelService
{
    public readonly Dictionary<string, string> Running = new(StringComparer.Ordinal);
    public readonly List<string> Calls = [];
    public Exception? FailStart, FailStop, FailStatus, FailHandshake;
    public long Rx, Tx;
    public DateTimeOffset? Handshake = DateTimeOffset.UnixEpoch;

    public Task<string> HandshakeAsync(CancellationToken ct = default) =>
        FailHandshake is { } e ? Task.FromException<string>(e) : Task.FromResult("1.0.0");

    public readonly List<string> SuppressedDns = [];
    public IReadOnlyList<KillSwitchEntry> KillSwitch = [];
    public IReadOnlyList<SplitDnsEntry> SplitDns = [];
    public readonly Dictionary<Guid, IReadOnlyList<RouteEntry>> Routes = [];
    public Exception? FailRoutes;

    public Task StartAsync(string alias, string contents, bool suppressDns = false, CancellationToken ct = default)
    {
        Calls.Add($"start {alias}");
        if (suppressDns) SuppressedDns.Add(alias);
        if (FailStart is { } e) return Task.FromException(e);
        Running[alias] = contents;
        return Task.CompletedTask;
    }

    public Task StopAsync(string alias, CancellationToken ct = default)
    {
        Calls.Add($"stop {alias}");
        if (FailStop is { } e) return Task.FromException(e);
        Running.Remove(alias);
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<TunnelRuntimeStatus>> StatusAsync(CancellationToken ct = default)
    {
        if (FailStatus is { } e) return Task.FromException<IReadOnlyList<TunnelRuntimeStatus>>(e);
        IReadOnlyList<TunnelRuntimeStatus> list = Running.Select(r =>
        {
            var config = WireGuardConfig.Parse(r.Value);
            return new TunnelRuntimeStatus
            {
                Name = r.Key,
                Peers = [new PeerRuntimeStatus
                {
                    PublicKey = config.PrimaryPeer?.PublicKey ?? "",
                    Endpoint = config.PrimaryPeer?.Endpoint ?? "198.51.100.1:51820",
                    LastHandshake = Handshake,
                    RxBytes = Rx,
                    TxBytes = Tx,
                    AllowedIPs = [.. config.PrimaryPeer?.AllowedIPs ?? []],
                }],
            };
        }).ToList();
        return Task.FromResult(list);
    }

    public readonly List<InventoryRoutingRequest> Inventory = [];

    public Task UpdateInventoryAsync(InventoryRoutingRequest request, CancellationToken ct = default)
    {
        Calls.Add($"inventory {request.Action.ToString().ToLowerInvariant()}{(request.UseCachedInventory ? " cached" : "")}");
        Inventory.Add(request);
        return Task.CompletedTask;
    }

    public Task SyncKillSwitchAsync(IReadOnlyList<KillSwitchEntry> entries, CancellationToken ct = default)
    {
        Calls.Add($"killswitch {string.Join(",", entries.Select(e => $"{e.Name}@{e.EndpointHost}:{e.EndpointPort}"))}");
        KillSwitch = entries;
        return Task.CompletedTask;
    }

    public Task SyncSplitDnsAsync(IReadOnlyList<SplitDnsEntry> entries, CancellationToken ct = default)
    {
        Calls.Add($"splitdns {string.Join(",", entries.SelectMany(e => e.Domains))}");
        SplitDns = entries;
        return Task.CompletedTask;
    }

    public List<Tunnel> Managed = [];
    public readonly Dictionary<Guid, string> ManagedConfigs = [];
    public readonly List<string> AdminCalls = [];
    public Exception? FailAdmin;
    public SystemSettings Settings = new();

    public Task<IReadOnlyList<Tunnel>> ListManagedAsync(CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<Tunnel>>(Managed.Select(t => System.Text.Json.JsonSerializer.Deserialize<Tunnel>(
            System.Text.Json.JsonSerializer.Serialize(t, Protocol.Json), Protocol.Json)!).ToList());

    public Task StartManagedAsync(Guid id, CancellationToken ct = default)
    {
        var record = Managed.Single(t => t.Id == id);
        Calls.Add($"start shared {record.ConfigPath}");
        Running[record.ConfigPath] = ManagedConfigs[id];
        return Task.CompletedTask;
    }

    public Task<SystemSettings> GetSystemSettingsAsync(CancellationToken ct = default) => Task.FromResult(Settings);

    /// Plays the service's part of each admin op (the real service validates and authorizes).
    public Task<T?> AdminAsync<T>(string op, object? args, CancellationToken ct = default)
    {
        AdminCalls.Add(op);
        if (FailAdmin is { } e) return Task.FromException<T?>(e);
        object? result = null;
        switch (args)
        {
            case InstallManagedArgs install:
                var parsed = WireGuardConfig.Parse(install.Contents);
                var record = new Tunnel
                {
                    Name = install.Name, ConfigPath = ConfigName.FileBaseName(install.Name), Scope = TunnelScope.Managed, ManagedPolicy = new(),
                    Dns = [.. parsed.Dns], Endpoint = parsed.PrimaryPeer?.Endpoint, AllowedIPs = [.. parsed.PrimaryPeer?.AllowedIPs ?? []],
                };
                Managed.Add(record);
                ManagedConfigs[record.Id] = install.Contents;
                result = record;
                break;
            case UpdateManagedArgs update:
                var target = Managed.Single(t => t.Id == update.Id);
                target.Name = update.Name;
                target.ManagedPolicy = update.Policy;
                if (update.Contents is { } c) ManagedConfigs[target.Id] = c;
                break;
            case ManagedIdArgs id when op == Ops.ReadManaged:
                result = ManagedConfigs[id.Id];
                break;
            case ManagedIdArgs id when op == Ops.DeleteManaged:
                Managed.RemoveAll(t => t.Id == id.Id);
                break;
            case SystemSettings settings:
                Settings = settings;
                break;
        }
        return Task.FromResult((T?)result);
    }

    public Task SyncRoutesAsync(Guid ownerId, IReadOnlyList<RouteEntry> entries, CancellationToken ct = default)
    {
        Calls.Add($"routes {string.Join(",", entries.Select(e => e.Cidr + (e.Tunnel is { } t ? "@" + t : "")))}");
        if (FailRoutes is { } e) return Task.FromException(e);
        if (entries.Count == 0) Routes.Remove(ownerId);
        else Routes[ownerId] = entries;
        return Task.CompletedTask;
    }
}

internal sealed class FakeInventory : IInventoryRunner
{
    public IReadOnlyList<string> Output = ["203.0.113.7/32"];
    public Exception? Fail;
    public int Runs;

    public Task<IReadOnlyList<string>> RunAsync(InventoryCommand command, CancellationToken ct)
    {
        Runs++;
        return Fail is { } e ? Task.FromException<IReadOnlyList<string>>(e) : Task.FromResult(Output);
    }
}

internal sealed class FakeNetwork : INetworkInfo
{
    public List<string> Physical = ["192.168.1.10"]; // IPv4-only LAN unless a test says otherwise
    public HashSet<IPFamily> Bypassed = [];
    public readonly Dictionary<string, string> Hosts = new() { ["exit.example"] = "203.0.113.20" };

    public IReadOnlyList<string> PhysicalAddresses(IReadOnlySet<string> tunnelAdapters) => Physical;
    public IReadOnlySet<IPFamily> BypassedFamilies(IReadOnlySet<IPFamily> families, IReadOnlySet<string> tunnelAdapters) =>
        families.Where(Bypassed.Contains).ToHashSet();
    public Task<IPAddress?> ResolveAsync(string host, CancellationToken ct = default) =>
        Task.FromResult(IPPrefix.TryParseAddress(host, out var ip) ? ip : Hosts.TryGetValue(host, out var a) ? IPAddress.Parse(a) : null);
}

internal sealed class FakeProbe : IServiceProbe
{
    public ServiceInstallState State = ServiceInstallState.Running;
    public ServiceInstallState Query() => State;
}

/// Reversible but not plain text, so tests can prove nothing is stored in clear.
internal sealed class FakeProtector : IConfigProtector
{
    private static readonly byte[] Marker = "FAKEDPAPI:"u8.ToArray();
    public byte[] Protect(byte[] plain) => [.. Marker, .. plain.Select(b => (byte)(b ^ 0x5A))];

    public byte[] Unprotect(byte[] data)
    {
        if (!data.AsSpan().StartsWith(Marker)) throw new System.Security.Cryptography.CryptographicException("not ours");
        return data[Marker.Length..].Select(b => (byte)(b ^ 0x5A)).ToArray();
    }
}

internal sealed class ManualTime : TimeProvider
{
    public DateTimeOffset Now = new(2026, 11, 6, 12, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset GetUtcNow() => Now;
    public void Advance(double seconds) => Now = Now.AddSeconds(seconds);
}

internal sealed class RecordingNotifier : INotifier
{
    public readonly List<string> Posted = [];
    public void Post(string title, string body) => Posted.Add($"{title}: {body}");
}

/// A TunnelManager over a temporary folder; deleted on dispose.
internal sealed class Harness : IDisposable
{
    public readonly string Root = Path.Combine(Path.GetTempPath(), "wt-client-tests-" + Guid.NewGuid().ToString("N"));
    public readonly FakeTunnelService Service = new();
    public readonly FakeProbe Probe = new();
    public readonly ManualTime Time = new();
    public readonly RecordingNotifier Notifier = new();
    public readonly FakeNetwork Network = new();
    public readonly FakeInventory Inventory = new();
    public readonly AppPaths Paths;
    public readonly ConfigStore Configs;
    public readonly LogService Log;
    public bool NotificationsEnabled = true;
    public TunnelManager Manager;

    public Harness()
    {
        Paths = new AppPaths(Root);
        Configs = new ConfigStore(Paths.Configs, new FakeProtector());
        Log = new LogService(Paths.LogFile);
        Manager = NewManager();
    }

    public TunnelManager NewManager() =>
        Manager = new TunnelManager(Service, Probe, Configs, new RecoverableJsonStore<List<Tunnel>>(Paths.TunnelsFile, () => []),
            Log, Notifier, () => NotificationsEnabled, Time, Network,
            new RecoverableJsonStore<List<HopChain>>(Paths.HopChainsFile, () => []), Inventory);

    public static string Config(string allowed = "10.0.0.0/24", string extra = "", string endpoint = "198.51.100.1:51820",
        string address = "10.0.0.2/32", string dns = "10.0.0.1") => $"""
        [Interface]
        PrivateKey = {WireGuardKey.Generate().PrivateKey}
        Address = {address}
        DNS = {dns}
        {extra}
        [Peer]
        PublicKey = {WireGuardKey.Generate().PublicKey}
        Endpoint = {endpoint}
        AllowedIPs = {allowed}
        """;

    public void Dispose()
    {
        try { Directory.Delete(Root, recursive: true); } catch (IOException) { }
    }

    public static string Text(byte[] data) => Encoding.UTF8.GetString(data);
}
