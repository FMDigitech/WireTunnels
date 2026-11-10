using System.Runtime.Versioning;
using Microsoft.Extensions.Logging.Abstractions;
using WireTunnels.Service.Managed;
using WireTunnels.Service.Native;
using WireTunnels.Service.Network;

namespace WireTunnels.Service;

/// `WireTunnels.Service.exe --cleanup`, run by the MSI on uninstall (never on upgrade). The inventory guards and the
/// kill switch are persistent WFP filters and survive a clean stop on purpose, so removing the product has to
/// drop them, and the policies in %ProgramData%\WireTunnels, or the destinations would stay blocked.
[SupportedOSPlatform("windows")]
internal static class UninstallCleanup
{
    public static int Run()
    {
        try
        {
            using (var firewall = new Firewall(NullLogger<Firewall>.Instance))
            {
                firewall.SetKillSwitch([]);
                firewall.SetInventoryGuards([]);
            }
            var engine = Wfp.Open(dynamic: false);
            try { Wfp.RemoveProviderAndSubLayer(engine); }
            finally { Wfp.Close(engine); }
            if (Directory.Exists(SecureFolder.Root)) Directory.Delete(SecureFolder.Root, recursive: true);
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"Cleanup failed: {e.Message}");
            return 1;
        }
    }
}
