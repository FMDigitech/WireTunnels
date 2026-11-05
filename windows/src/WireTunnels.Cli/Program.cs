using WireTunnels.Contracts;
using WireTunnels.Core.Config;

// wiretunnels: drive the service without the app (automation, scripts, PowerToys Run, Task Scheduler).
const string Usage = """
    Usage:
      wiretunnels connect <file.conf> [name]   Connect a tunnel (name defaults to the file name)
      wiretunnels disconnect <name>            Disconnect a tunnel
      wiretunnels status                       Show your connected tunnels
      wiretunnels genkey                       Print a new private and public key
    """;

try
{
    switch (args)
    {
        case ["connect", var path, ..]:
        {
            var name = args.Length > 2 ? args[2] : Path.GetFileNameWithoutExtension(path);
            var contents = await File.ReadAllTextAsync(path);
            var config = WireGuardConfig.Parse(contents);
            foreach (var w in config.Warnings) Console.Error.WriteLine($"warning: {w}");
            if (!config.IsValid) return Fail(string.Join("\n", config.Errors.Select(e => e.Message)));
            await using var client = await Connect();
            await client.CallAsync(Ops.StartTunnel, new StartTunnelArgs { Name = ConfigName.FileBaseName(name), Contents = contents });
            Console.WriteLine($"Connected {ConfigName.DisplayName(name)}");
            return 0;
        }
        case ["disconnect", var name]:
        {
            await using var client = await Connect();
            await client.CallAsync(Ops.StopTunnel, new TunnelNameArgs { Name = ConfigName.FileBaseName(name) });
            Console.WriteLine($"Disconnected {ConfigName.DisplayName(name)}");
            return 0;
        }
        case ["status"]:
        {
            await using var client = await Connect();
            var tunnels = await client.CallAsync<List<TunnelRuntimeStatus>>(Ops.RuntimeStatusSnapshot, null) ?? [];
            if (tunnels.Count == 0) Console.WriteLine("No connected tunnels");
            foreach (var t in tunnels)
            {
                Console.WriteLine($"{t.Name}  public key {t.PublicKey}  port {t.ListenPort}");
                foreach (var p in t.Peers)
                    Console.WriteLine($"  peer {p.PublicKey}  endpoint {p.Endpoint ?? "-"}  handshake {p.LastHandshake?.ToLocalTime().ToString() ?? "never"}  rx {p.RxBytes} B  tx {p.TxBytes} B");
            }
            return 0;
        }
        case ["genkey"]:
        {
            var (priv, pub) = WireGuardKey.Generate();
            Console.WriteLine($"PrivateKey = {priv}\nPublicKey = {pub}");
            return 0;
        }
        default:
            Console.Error.WriteLine(Usage);
            return 2;
    }
}
catch (Exception e) when (e is ServiceException or IOException or UnauthorizedAccessException)
{
    return Fail(e.Message);
}

static Task<ServiceClient> Connect() => ServiceClient.ConnectAsync(TimeSpan.FromSeconds(5));

static int Fail(string message)
{
    Console.Error.WriteLine(message);
    return 1;
}
