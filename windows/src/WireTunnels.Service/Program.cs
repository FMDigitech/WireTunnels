using Microsoft.Extensions.Hosting.WindowsServices;
using WireTunnels.Service.Ipc;
using WireTunnels.Service.Managed;
using WireTunnels.Service.Network;
using WireTunnels.Service.WireGuard;

if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
{
    Console.Error.WriteLine("WireTunnels.Service requires Windows 10 version 2004 or later.");
    return 1;
}

if (args is ["--cleanup"]) return WireTunnels.Service.UninstallCleanup.Run();

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options => options.ServiceName = "WireTunnels");
// Replaces the lifetime AddWindowsService registered, to receive logoff notifications.
if (WindowsServiceHelpers.IsWindowsService()) builder.Services.AddSingleton<IHostLifetime, SessionAwareLifetime>();
builder.Services.AddSingleton<IFirewall, Firewall>();
builder.Services.AddSingleton<INrptStore, RegistryNrptStore>();
builder.Services.AddSingleton<IRouteTable, WindowsRouteTable>();
builder.Services.AddSingleton<IJournal, VolatileRegistryJournal>();
builder.Services.AddSingleton<ITunnelBackend, TunnelRunner>();
builder.Services.AddSingleton<NetworkPolicy>();
builder.Services.AddSingleton<IInventoryStore, ProgramDataInventoryStore>();
builder.Services.AddSingleton<InventoryPolicy>();
builder.Services.AddSingleton<IManagedStore, ProgramDataManagedStore>();
builder.Services.AddSingleton<RequestDispatcher>();
// Before the pipe: recovery runs before the first request, and the clean-stop restore after the last one.
builder.Services.AddHostedService<NetworkLifetime>();
builder.Services.AddHostedService<PipeServer>();

// Stopping the service disposes TunnelRunner, which removes every adapter it created.
builder.Build().Run();
return 0;
