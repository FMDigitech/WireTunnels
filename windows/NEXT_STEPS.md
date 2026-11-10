# WireTunnels for Windows — next steps (phase 3 onward)

State on 2026-11-10, branch `windows-port`: phases 1–5 done (phase 3 except the On-Demand section, phase 6), on .NET 10;
244 unit tests, 7 opt-in live network tests, 5 opt-in UI tests.
Architecture and rationale: [`../docs/WINDOWS_PORT_ARCHITECTURE.md`](../docs/WINDOWS_PORT_ARCHITECTURE.md).
Every phase: port the macOS behaviour (the Swift code and `Tests/`, `Scripts/test_*.sh` are the spec),
add xUnit tests for the new logic, keep `dotnet test` green, run `graphify update .` after code changes.

## 0. First session on Windows (before phase 3) — validate phase 2

Nothing in `src/WireTunnels.Service/Native` has run on Windows yet. On a Windows 11 VM:

1. Follow `README.md` → install the service, put `wireguard.dll` next to it, `wiretunnels connect` a real `.conf`.
2. Check, and fix in code if wrong:
   - adapter appears, handshake happens, `wiretunnels status` shows rx/tx (validates `ConfigBlob` offsets and `WireGuardNative`);
   - `ipconfig` shows the address, `route print` the AllowedIPs routes, interface metric 0 (validates `IpHelper` row offsets);
   - DNS servers on the adapter (`Get-DnsClientServerAddress`); confirm `SetInterfaceDnsSettings` accepts the comma-separated list;
   - full tunnel (`0.0.0.0/0`) does not loop: confirm wireguard-nt routes its own packets past the adapter (`TunnelRunner` relies on it; otherwise add an endpoint host route via the physical gateway);
   - `PipeServer.Identify` works with the client's `TokenImpersonationLevel.Identification` (else raise the client to `Impersonation`);
   - a second Windows user cannot stop or see the first user's tunnel; an elevated admin can;
   - killing the service process removes the adapter, routes and DNS (no orphaned state);
   - Release build rejects a CLI copied outside `C:\Program Files\WireTunnels`.
3. Add a `WinVerifyTrust` check of `wireguard.dll` (shortcut noted in `WireGuardNative.cs`).

**Done on 2026-11-06** (Windows 11 IoT Enterprise 26200 x64, wireguard-nt 1.1, .NET SDK 8.0.427). All checks pass:
handshake and rx/tx, address, AllowedIPs routes with metric 0, interface metric 0 and MTU 1420, DNS (comma list,
IPv6 server, search domain), full tunnel without loop, per-user isolation (standard user and non-elevated admin are
denied; elevated admin allowed), no orphaned adapter/routes/DNS after killing the service, CLI outside the install
folder rejected. Fixes made along the way:
- `PipeServer.Identify` crashed on every connection: with an Identification-level token the thread cannot open files,
  so `WindowsIdentity` failed to load `System.Security.Claims`. It now only opens the thread token while impersonating.
  The client stays at `Identification`.
- `PipeServer.ServeAsync` logs unexpected exceptions (they were lost in the fire-and-forget task).
- `ServiceClient` reports "refused the connection" instead of "Pipe is broken" when the service rejects the client.
- `wireguard.dll` is loaded by full path only after `WinTrust.Verify` (valid chain + signer `WireGuard LLC`).
Notes for later phases: wireguard-nt 1.1 added `WIREGUARD_ALLOWED_IP.Flags` at offset 20 (size unchanged, zero = add);
the service has no recovery actions after a crash (set them in the MSI, phase 7, `sc failure`); service events go to
the Application log under the source `WireTunnels.Service`; a non-present PnP node `SWD\WIREGUARD\{guid}` per alias
stays after disconnect (reused by the stable GUID, as with wireguard-windows).

## 3. App MVP (WinUI 3) — `src/WireTunnels.App`

**Done on 2026-11-06.** Built with the .NET CLI only (no Visual Studio): Windows App SDK 2.6.5 self-contained,
unpackaged, H.NotifyIcon.WinUI 2.3.2 (2.4 needs .NET 10). App logic lives in `src/WireTunnels.Client` (net8.0, 41
tests on any OS); the WinUI project holds only views. Verified on this PC by driving the real UI with UI Automation:
import of a `.conf` through the file picker, connect/disconnect from the list, the detail pane and the tray flyout,
single instance (a second launch brings the dashboard forward), `--background` start, close = hide to tray, Quit =
disconnect all then exit, setup wizard when the service is unreachable, settings. Decisions and findings:
- The exe is `WireTunnels.App.exe`: `WireTunnels.exe` would collide with `wiretunnels.exe` (the CLI) on NTFS.
- `EnableMsixTooling` is required, otherwise `dotnet publish` drops the app's `.pri` and the compiled XAML.
- `TaskbarIcon` disposes the previous `System.Drawing.Icon` when the icon changes: create a new one every time
  (a cached icon crashed the process in native code).
- x:Bind functions bound to `Visibility` must return `Visibility` (the XAML compiler breaks the bool cast).
- A tunnel that was active when the app closed and is gone at startup (reboot, service restart) is reconciled
  silently instead of being reported as "Connection lost".
- Not ported yet: the Shared page and "Make Shared" (phase 5), the On-Demand section of the detail pane (phase 6).
- **Completed on 2026-11-09:** QR code import (image file, drag & drop, clipboard; ZXing.Net 0.16.9 in
  `Client/QrCode.cs`, pixels decoded by `Windows.Graphics.Imaging` in `ImportDialog`), Reset App Data (Settings >
  Advanced: stops tunnels, removes inventory protection, deletes configs, metadata, log, preferences and Launch at
  Login), UI smoke tests with FlaUI (`tests/WireTunnels.App.UITests`, opt-in; they run the installed app on a
  throw-away data folder through `WIRETUNNELS_DATA_DIR`, which also gives that app its own single-instance key).
  The UI tests found a crash: rebuilding the Settings page re-parented a TextBlock (stowed exception 0xc000027b).
- **Moved to .NET 10 LTS on 2026-11-10** (.NET 8 support ended that day): every project targets `net10.0`, Microsoft
  packages 10.0.14, H.NotifyIcon.WinUI 2.4.1. `MVVMTK0045` is suppressed in the app: `[ObservableProperty]` on fields
  only matters for Native AOT, which the app does not use. UI tests pass against the installed .NET 10 build.

Original plan:

1. `dotnet new winui` (or VS template "Blank App, Packaged/Unpackaged (WinUI 3)"), unpackaged, net8.0-windows10.0.19041; reference Core + Contracts; add to the sln.
2. Single instance via `AppInstance.FindOrRegisterForKey`; tray with `H.NotifyIcon.WinUI` (flyout = macOS `MenuBarView`, context menu: Dashboard, Connect favorites, Disconnect all, Quit).
3. `Services/TunnelManager` (port of `WireTunnels/Services/TunnelManager.swift`, MVVM with CommunityToolkit.Mvvm): owns `List<Tunnel>`, uses `ServiceClient`, polls `RuntimeStatusSnapshot` every 2 s, `TunnelWarnings.Compute`, connect/disconnect/all/favorites.
4. Storage: `%LOCALAPPDATA%\WireTunnels\{configs,metadata,logs}`; configs encrypted with DPAPI CurrentUser (`ProtectedData`) as `<alias>.conf.dpapi`; metadata via `RecoverableJsonStore<List<Tunnel>>`.
5. Dashboard: `NavigationView` with the macOS sidebar (All, Active, Shared, Favorites, Multi-Hop, Warnings, Settings, Log) and a detail page (status, handshake, endpoint, DNS, AllowedIPs, rx/tx, sparkline with `Polyline`).
6. Config: import `.conf` (picker + drag & drop), basic and advanced editor, templates (port `Views/Config/TemplatePickerView.swift`), validation with `WireGuardConfig.Parse`; keys with `WireGuardKey.Generate`.
7. Quit = disconnect all with Retry / Cancel dialog (macOS `prepareForQuit`); toast notifications via `AppNotificationManager`; launch at login via `HKCU\...\Run`.
8. Setup wizard: service missing, stopped or wrong `ProtocolRevision` → clear message.

## 4. Network parity — service

**Done on 2026-11-09** (point 7 completed the same day, see below). Protocol revision 2 adds `syncKillSwitch`, `syncSplitDNS`,
`syncRoutes` and `StartTunnelArgs.SuppressDns`. Service: `Network/FirewallRules` (pure rule sets, tested on any OS),
`Native/Wfp` + `Network/Firewall`, `Network/SplitDns` (NRPT), `Network/NetworkPolicy` (per-SID state, diff, journal,
recovery). Client: `TunnelManager.Network.cs` (kill switch, split DNS, exclusions, hop chains, leaks), `NetworkInfo`.
App: kill switch / leak / exclusions / split DNS sections in the detail pane, Multi-Hop page. Verified on this PC
(Windows 11 Pro 26100) with `LiveNetworkTests` (opt-in, see README) and an end-to-end run through the installed service:
NRPT rule active and no adapter DNS with split DNS, exclusion via the physical gateway, kill switch blocks the internet
and passes loopback, still blocks after the service is killed and restarted by recovery, released when turned off,
multi-hop host routes on the hop adapter and the physical gateway, clean stop and quit leave nothing behind.
Decisions and findings:
- Kill switch filters are persistent; the journal is a **volatile** registry key (`HKLM\SOFTWARE\WireTunnels\Runtime`),
  which Windows drops at boot. Service start without a journal = fresh boot: leftover filters are removed, so a reboot
  never stays blocked (macOS pf rules do not survive a reboot either). With a journal = crash: the block is re-applied
  and our gateway routes are removed. A clean service stop clears everything (uninstall is safe).
- DNS leak guard (dynamic WFP filters, live with the adapter): a full tunnel with DNS on its adapter blocks port 53
  except to its servers and loopback. Split DNS and hop legs skip it (no adapter DNS).
- Multi-hop needs a second route on Windows: wireguard-nt only skips its own adapter when routing its UDP, so the
  hop's endpoint gets a host route via the physical gateway, or the hop's packets would follow the exit's default route.
- A blocked UDP `sendto` is dropped silently by WFP; tests check the verdict with TCP `connect` (AccessDenied).
- NRPT: one local rule per domain (`DnsPolicyConfig\WireTunnels-<domain>`, marker in `Comment`, per SID). When Group
  Policy defines NRPT rules Windows ignores local ones: split DNS then fails with a clear message.
- Excluded routes and kill switch endpoints use the pre-VPN gateway the service finds itself (lowest route + interface
  metric outside our adapters); the client only sends CIDRs.
- Reconnecting exclusions/chains after a gateway change is phase 6.

**Point 7, inventory AllowedIPs (protocol revision 3, `updateInventoryRouting`).** Service: `Network/Inventory.cs`
(port of `InventoryRoutingService`), `ConfigBlob.PeerAllowedIPs` (replaces one peer's AllowedIPs in place),
WFP prefix masks and "interface not equal" conditions, a separate inventory provider key. Client:
`InventoryCommandRunner` (no shell, 60 s, 8 MiB, process tree killed on timeout), `TunnelManager.Inventory.cs`.
App: Inventory AllowedIPs section of the detail pane. Verified on this PC end to end: static prefixes blocked before
connecting, discovered prefix routed through the tunnel and in its AllowedIPs, both allowed only through it, blocked
again after disconnect and after a service restart, lifted only by removing the command. Decisions:
- Guard filters are persistent and survive reboots and clean stops; policies live in
  `%ProgramData%\WireTunnels\inventory.json` (folder owned by Administrators, ACL SYSTEM + Administrators, no
  inheritance; a folder pre-created by someone else is refused). At service start every policy is re-installed as
  blocked. **Phase 7: uninstall must remove the policies** (or the destinations stay blocked).
- The block is "remote prefix AND local interface != tunnel LUID" in both directions, weight above the kill switch's
  adapter permit (no other tunnel can carry the destinations); the right adapter falls through to the kill switch.
  The peer endpoint stays reachable over UDP (any process: WFP has no cheap "root only" like pf's `user root`).
- WFP reauthorizes existing flows when filters change, so the pf state purge (`pfctl -k`) has no equivalent.
- A failed apply fails closed (destinations blocked until the tunnel reconnects) instead of macOS's partial rollback.
- Interface monitoring is not needed: the service owns the adapters and closes the exception when it stops one.
- Prefix filters are chunked (256 per filter); not measured with 100k-entry inventories yet. The pipe message limit
  is now 16 MiB.

Add ops to `Contracts/Protocol.cs` (bump `Protocol.Revision`) and handlers in `RequestDispatcher`, each idempotent and declarative (the client sends the full desired state):

1. `SyncKillSwitch` → WFP (`fwpuclnt.dll`): own provider + sublayer GUID; permit tunnel LUID, peer endpoint UDP, loopback, DHCP, essential ICMPv6; block the rest. Persistent filters only for an armed kill switch. Port rules/tests from `Tests/KillSwitchRulesTests.swift`.
2. DNS leak guard: WFP block of port 53 on non-tunnel interfaces for full tunnels.
3. `SyncSplitDNS` → NRPT rules marked as WireTunnels (only ours are ever removed). Port `Scripts/test_split_dns.sh`.
4. `SyncRoutes(ownerId = SID)` → excluded routes via the pre-VPN gateway (`GetBestRoute2`); users cannot touch other SIDs' routes.
5. State journal in `%ProgramData%\WireTunnels\state` for NRPT/WFP only; reconcile at service start.
6. Multi-hop (`TunnelManager.connectHopChain`): host route of the exit endpoint on the hop LUID.
7. Inventory AllowedIPs (`Shared/InventoryRouting.swift`, `WireTunnelsHelper/InventoryRouting*.swift`): the command runs in the app as the user; the service applies prefixes via `UpdateInventoryRouting`; port the `IPPrefix.inventoryPrefixes` limits.
8. IP-family leak detector (`Models/IPFamilyLeak.swift`, `Services/IPFamilyLeakFix.swift`) into Core + warnings.

## 5. Multi-user (managed shared tunnels)

**Done on 2026-11-10.** Protocol revision 4. Service: `Managed/ManagedStore.cs` (`%ProgramData%\WireTunnels\managed\`
`tunnels.json`, `settings.json`, `configs\<id>.conf.dpapi`, DPAPI LocalMachine inside the SYSTEM + Administrators folder,
`Managed/SecureFolder.cs` now shared with the inventory store), `Ipc/RequestDispatcher.Managed.cs`, `Ipc/SessionAwareLifetime.cs`.
CLI: `wiretunnels elevated <request> <response file>` (the UAC helper). Client: `Elevation.cs`, `TunnelManager.Managed.cs`.
App: Sharing / Shared Tunnel cards in the detail pane, admin kill switch and split DNS for shared tunnels, editing a shared
config, Settings > Administrator. Verified on this PC through the installed service and the relay: install, sanitized list
(no private key), policy with split DNS (NRPT rule, no adapter DNS), start, status, connected users, read, ACL
SYSTEM + Administrators, config not in plain text, stop (adapter and NRPT gone), delete. Not verified live: the UAC prompt
from a non-elevated app (needs a person) and the rejection of a non-elevated caller (unit tests only). Decisions:
- A shared tunnel is **machine-wide**: once up it is up for every user and all of them see it. "Disconnect" stops it for
  everyone, as the policy allows. As on macOS, Quit and Reset App Data disconnect shared tunnels too (a policy that forbids
  disconnecting makes the quit fail with Retry / Cancel), and so does a logoff (macOS quits the app at logout).
- No staging: users start a shared tunnel by id (`startManagedTunnel`) and the service reads its own copy, so the config
  never reaches a non-admin client. Connected users are tracked by the service on start (no mark ops) and kept in memory
  only (the adapters do not outlive the service either).
- Its split DNS is applied by the service (one NRPT rule set per tunnel); the apps skip shared tunnels in `syncSplitDNS`,
  otherwise two users' apps would conflict over the same domains. Its kill switch is still armed by each user's app.
- A record is a Core `Tunnel` with `Scope = Managed` whose `ConfigPath` holds the adapter alias; renaming or replacing the
  config, and deleting, require it to be disconnected. A personal tunnel cannot take a shared tunnel's alias.
- Admin ops need an elevated token: the app runs `wiretunnels.exe elevated` through UAC with the request on the command
  line (it cannot be changed after approval), and reads the response from `%LOCALAPPDATA%\WireTunnels\elevated`.
  Admin controls are shown to administrator accounts only (split token or elevated); a standard user does not see them.
- Logoff (`SERVICE_CONTROL_SESSIONCHANGE`): when a user's last known session ends, their personal tunnels stop, running
  shared tunnels that users may disconnect stop, and their kill switch, split DNS and routes are dropped. A session is "known" once the app or CLI talked to the service from it.
  No `PRESHUTDOWN` handler: shutdown stops the service, and a clean stop already removes everything.
- Not ported: importing a `.conf` straight as shared (import it, then Make Shared), the On-Demand rule of a shared tunnel
  (phase 6; the field is stored and passed through).

Original plan:

1. `%ProgramData%\WireTunnels\managed\{configs,metadata}` with ACL SYSTEM + Administrators; configs DPAPI LocalMachine.
2. Ops from the macOS protocol: List/Read/Install/Update/Delete managed, StageManaged, Mark connected/disconnected, ListManagedTunnelUsers, Get/SetSystemSettings. Writes and `ReadManaged` need `ClientIdentity.IsElevatedAdmin`; users get sanitized metadata only.
3. App: admin actions go through a small elevated helper process (UAC) that talks to the pipe with an elevated token.
4. `SERVICE_CONTROL_SESSIONCHANGE` / `PRESHUTDOWN`: stop the personal tunnels of a user who logs off.

## 6. Automation

1. NetworkMonitor in the app: `NotifyIpInterfaceChange`, `NetworkInformation.NetworkStatusChanged`, wake via `PowerModeChanged`; debounce like `NetworkChangeScheduler.swift`.
2. SSID via `WlanQueryInterface` (handle a denied location permission in the UI); rules with `AutoConnectNetworkMatch.Matches`.
3. Recovery: wake / DHCP change / DDNS re-resolution → reconnect only the affected tunnels (`handleSystemWake`, `handleLocalAddressChange`, `checkEndpointReResolution`).
4. CLI talks to the running app when present; `wiretunnels://connect?name=` URI protocol.

## 7. Distribution

1. WiX MSI: Program Files, service install (auto start), `wireguard.dll` per arch (x64, ARM64), `.conf` file association.
2. Signing: app, service, CLI and MSI with the same certificate (Azure Trusted Signing or EV).
3. Updates: NetSparkleUpdater with an Ed25519-signed Windows appcast; verify the MSI's Authenticode signature before running it.
4. Release checklist: Release build, all tests, smoke test on clean Windows 10 2004 and Windows 11 (x64 + ARM64).
