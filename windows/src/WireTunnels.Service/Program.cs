using WireTunnels.Service.Ipc;
using WireTunnels.Service.WireGuard;

if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
{
    Console.Error.WriteLine("WireTunnels.Service requires Windows 10 version 2004 or later.");
    return 1;
}

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options => options.ServiceName = "WireTunnels");
builder.Services.AddSingleton<ITunnelBackend, TunnelRunner>();
builder.Services.AddSingleton<RequestDispatcher>();
builder.Services.AddHostedService<PipeServer>();

// Stopping the service disposes TunnelRunner, which removes every adapter it created.
builder.Build().Run();
return 0;
