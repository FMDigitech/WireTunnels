using System.Runtime.Versioning;
using System.ServiceProcess;
using Microsoft.Extensions.Hosting.WindowsServices;
using Microsoft.Extensions.Options;

namespace WireTunnels.Service.Ipc;

/// The Windows service lifetime plus SERVICE_CONTROL_SESSIONCHANGE: a logoff stops that user's personal tunnels.
/// Shutdown needs nothing extra: it stops the service, and a clean stop removes every adapter and policy.
[SupportedOSPlatform("windows")]
internal sealed class SessionAwareLifetime : WindowsServiceLifetime
{
    private readonly RequestDispatcher _dispatcher;
    private readonly ILogger<SessionAwareLifetime> _log;

    public SessionAwareLifetime(IHostEnvironment environment, IHostApplicationLifetime applicationLifetime, ILoggerFactory loggerFactory,
        IOptions<HostOptions> optionsAccessor, IOptions<WindowsServiceLifetimeOptions> windowsServiceOptionsAccessor, RequestDispatcher dispatcher)
        : base(environment, applicationLifetime, loggerFactory, optionsAccessor, windowsServiceOptionsAccessor)
    {
        _dispatcher = dispatcher;
        _log = loggerFactory.CreateLogger<SessionAwareLifetime>();
        CanHandleSessionChangeEvent = true;
    }

    protected override void OnSessionChange(SessionChangeDescription change)
    {
        if (change.Reason != SessionChangeReason.SessionLogoff) return;
        _ = Task.Run(async () =>
        {
            try { await _dispatcher.SessionLoggedOffAsync(change.SessionId); }
            catch (Exception e) { _log.LogError(e, "Logoff cleanup failed for session {Session}", change.SessionId); }
        });
    }
}
