using System.Text;
using WireTunnels.Contracts;
using WireTunnels.Core.Config;
using WireTunnels.Core.Models;
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

    public Task StartAsync(string alias, string contents, CancellationToken ct = default)
    {
        Calls.Add($"start {alias}");
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
                    Endpoint = "198.51.100.1:51820",
                    LastHandshake = Handshake,
                    RxBytes = Rx,
                    TxBytes = Tx,
                    AllowedIPs = [.. config.PrimaryPeer?.AllowedIPs ?? []],
                }],
            };
        }).ToList();
        return Task.FromResult(list);
    }
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
            Log, Notifier, () => NotificationsEnabled, Time);

    public static string Config(string allowed = "10.0.0.0/24", string extra = "") => $"""
        [Interface]
        PrivateKey = {WireGuardKey.Generate().PrivateKey}
        Address = 10.0.0.2/32
        DNS = 10.0.0.1
        {extra}
        [Peer]
        PublicKey = {WireGuardKey.Generate().PublicKey}
        Endpoint = 198.51.100.1:51820
        AllowedIPs = {allowed}
        """;

    public void Dispose()
    {
        try { Directory.Delete(Root, recursive: true); } catch (IOException) { }
    }

    public static string Text(byte[] data) => Encoding.UTF8.GetString(data);
}
