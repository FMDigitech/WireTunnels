# WireTunnels for Windows — next steps (phase 3 onward)

State on 2026-11-05, branch `windows-port`: phases 1–2 done (Core, Contracts, Service MVP, CLI; 97 tests).
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

Needs Windows + Visual Studio with the Windows App SDK workload.

1. `dotnet new winui` (or VS template "Blank App, Packaged/Unpackaged (WinUI 3)"), unpackaged, net8.0-windows10.0.19041; reference Core + Contracts; add to the sln.
2. Single instance via `AppInstance.FindOrRegisterForKey`; tray with `H.NotifyIcon.WinUI` (flyout = macOS `MenuBarView`, context menu: Dashboard, Connect favorites, Disconnect all, Quit).
3. `Services/TunnelManager` (port of `WireTunnels/Services/TunnelManager.swift`, MVVM with CommunityToolkit.Mvvm): owns `List<Tunnel>`, uses `ServiceClient`, polls `RuntimeStatusSnapshot` every 2 s, `TunnelWarnings.Compute`, connect/disconnect/all/favorites.
4. Storage: `%LOCALAPPDATA%\WireTunnels\{configs,metadata,logs}`; configs encrypted with DPAPI CurrentUser (`ProtectedData`) as `<alias>.conf.dpapi`; metadata via `RecoverableJsonStore<List<Tunnel>>`.
5. Dashboard: `NavigationView` with the macOS sidebar (All, Active, Shared, Favorites, Multi-Hop, Warnings, Settings, Log) and a detail page (status, handshake, endpoint, DNS, AllowedIPs, rx/tx, sparkline with `Polyline`).
6. Config: import `.conf` (picker + drag & drop), basic and advanced editor, templates (port `Views/Config/TemplatePickerView.swift`), validation with `WireGuardConfig.Parse`; keys with `WireGuardKey.Generate`.
7. Quit = disconnect all with Retry / Cancel dialog (macOS `prepareForQuit`); toast notifications via `AppNotificationManager`; launch at login via `HKCU\...\Run`.
8. Setup wizard: service missing, stopped or wrong `ProtocolRevision` → clear message.

## 4. Network parity — service

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
