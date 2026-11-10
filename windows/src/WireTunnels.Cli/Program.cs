using WireTunnels.Contracts;
using WireTunnels.Core.Config;

// wiretunnels: drive the service without the app (automation, scripts, PowerToys Run, Task Scheduler).
const string Usage = """
    Usage:
      wiretunnels connect <file.conf> [name]   Connect a tunnel (name defaults to the file name)
      wiretunnels connect <saved name>         Connect a tunnel saved in the app (through the app)
      wiretunnels disconnect <name>            Disconnect a tunnel (through the app when it runs)
      wiretunnels disconnect-all               Disconnect every tunnel in the app
      wiretunnels status                       Show your connected tunnels
      wiretunnels genkey                       Print a new private and public key
    """;

try
{
    switch (args)
    {
        case ["connect", var saved] when !File.Exists(saved) && !saved.EndsWith(".conf", StringComparison.OrdinalIgnoreCase):
            return OpenLink(new AppLink(AppLinkAction.Connect, saved), $"Asked WireTunnels to connect {saved}");
        case ["disconnect-all"]:
            return OpenLink(new AppLink(AppLinkAction.DisconnectAll), "Asked WireTunnels to disconnect all tunnels");
        case ["disconnect", var appName] when AppIsRunning():
            // The app owns what it connected: going through it keeps its state (and On-Demand suppression) right.
            return OpenLink(new AppLink(AppLinkAction.Disconnect, appName), $"Asked WireTunnels to disconnect {appName}");
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
        case ["elevated", var encoded, var responsePath]:
        {
            // Run by the app through UAC for shared-tunnel admin ops: relays one request with this (elevated) token.
            // The request comes on the command line, so it cannot change after the user approved the prompt.
            var full = Path.GetFullPath(responsePath);
            var allowed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WireTunnels") + Path.DirectorySeparatorChar;
            if (!full.StartsWith(allowed, StringComparison.OrdinalIgnoreCase)) return Fail("Invalid response path");
            var request = System.Text.Json.JsonSerializer.Deserialize<Request>(Convert.FromBase64String(encoded), Protocol.Json)
                ?? throw new InvalidDataException("Empty request");
            Response response;
            try
            {
                await using var client = await Connect();
                response = await client.SendAsync(request);
            }
            catch (ServiceException e)
            {
                response = new Response { Error = e.Message };
            }
            await File.WriteAllBytesAsync(full, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(response, Protocol.Json));
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
catch (Exception e) when (e is ServiceException or IOException or UnauthorizedAccessException or FormatException or System.Text.Json.JsonException)
{
    return Fail(e.Message);
}

// The app in this logon session (the link would start one otherwise, which is fine for connect).
static bool AppIsRunning()
{
    var session = System.Diagnostics.Process.GetCurrentProcess().SessionId;
    return System.Diagnostics.Process.GetProcessesByName("WireTunnels.App").Any(p => p.SessionId == session);
}

// Hands a wiretunnels:// link to the app (started in the notification area if needed). Fire and forget, like
// the macOS intents: the app reports the result in its own notifications.
static int OpenLink(AppLink link, string message)
{
    try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(link.ToString()) { UseShellExecute = true }); }
    catch (System.ComponentModel.Win32Exception e) { return Fail($"WireTunnels is not installed for this user ({e.Message}). Start the app once."); }
    Console.WriteLine(message);
    return 0;
}

static Task<ServiceClient> Connect() => ServiceClient.ConnectAsync(TimeSpan.FromSeconds(5));

static int Fail(string message)
{
    Console.Error.WriteLine(message);
    return 1;
}
