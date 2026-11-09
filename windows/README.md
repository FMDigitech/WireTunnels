# WireTunnels for Windows

Native Windows port of WireTunnels. Architecture: [`../docs/WINDOWS_PORT_ARCHITECTURE.md`](../docs/WINDOWS_PORT_ARCHITECTURE.md).
Next phases, step by step: [`NEXT_STEPS.md`](NEXT_STEPS.md).

## Layout

| Project | Role |
|---|---|
| `src/WireTunnels.Core` | Platform-neutral logic: models (same JSON as macOS `tunnels.json`), `.conf` parser and validation, DNS, IP prefixes, on-demand matching, warnings, recoverable JSON store, X25519 keys |
| `src/WireTunnels.Contracts` | Named-pipe protocol (framing, operations, DTOs) and `ServiceClient` |
| `src/WireTunnels.Service` | Windows Service (LocalSystem): pipe server with per-user authorization, wireguard-nt adapters, addresses, routes, metric/MTU, DNS; kill switch and DNS leak guard (WFP), split DNS (NRPT), excluded and multi-hop routes |
| `src/WireTunnels.Cli` | `wiretunnels.exe connect / disconnect / status / genkey` |
| `src/WireTunnels.Client` | App logic without UI (port of `TunnelManager.swift`): tunnels, connect/disconnect, status polling, kill switch, split DNS, exclusions, multi-hop, IPv4/IPv6 leaks, DPAPI-encrypted config store, log, quit |
| `src/WireTunnels.App` | `WireTunnels.App.exe`, WinUI 3: notification-area icon + flyout, dashboard, import / new / edit, setup wizard, settings, log |
| `tests/*` | xUnit; Core, Service and Client tests run on any OS |

Not yet implemented (see the plan in the architecture doc): managed shared tunnels, on-demand rules,
session/logoff handling, installer, updater.

## Build and test

Requires the .NET 8 SDK.

```powershell
dotnet test
dotnet publish src/WireTunnels.Service -c Release -r win-x64 --self-contained -o out
dotnet publish src/WireTunnels.Cli     -c Release -r win-x64 --self-contained -o out
dotnet publish src/WireTunnels.App     -c Release -r win-x64 --self-contained -o out
```

`LiveNetworkTests` exercise the real WFP, routing table, NRPT and registry with harmless values (TEST-NET
addresses, a dynamic WFP session that blocks this PC's traffic for about a second). They are opt-in, from an
elevated prompt: `$env:WIRETUNNELS_LIVE_TESTS = '1'; dotnet test tests\WireTunnels.Service.Tests`.

`tests/WireTunnels.App.UITests` drive the installed app with UI Automation (FlaUI) on a temporary data folder
(`WIRETUNNELS_DATA_DIR`), so your own tunnels are not touched. Opt-in, after installing the build under test:
`$env:WIRETUNNELS_UI_TESTS = '1'; dotnet test tests\WireTunnels.App.UITests` (`WIRETUNNELS_APP` overrides the exe).

The app needs no Visual Studio: the Windows App SDK is a NuGet package and ships self-contained next to the exe.
It is named `WireTunnels.App.exe` because NTFS is case-insensitive and the CLI is `wiretunnels.exe` in the same folder.

## Run on Windows (manual, until the installer exists)

1. Download the signed `wireguard-nt` package from <https://download.wireguard.com/wireguard-nt/> and copy
   `bin\amd64\wireguard.dll` (or `arm64`) into `out\`.
2. Copy `out\` to `C:\Program Files\WireTunnels\` (only administrators can write there; Release builds
   accept pipe clients only from this directory).
3. From an elevated prompt:
   ```powershell
   sc.exe create WireTunnels binPath= "C:\Program Files\WireTunnels\WireTunnels.Service.exe" start= auto
   sc.exe start WireTunnels
   ```
4. As a normal user, start `C:\Program Files\WireTunnels\WireTunnels.App.exe` (it lives in the notification area;
   closing the dashboard hides it, Quit disconnects every tunnel first), or use the CLI:
   ```powershell
   & "C:\Program Files\WireTunnels\wiretunnels.exe" connect C:\path\office.conf
   & "C:\Program Files\WireTunnels\wiretunnels.exe" status
   & "C:\Program Files\WireTunnels\wiretunnels.exe" disconnect office
   ```
   Release builds of the service only accept the app and the CLI from its own folder; a Debug app run from
   `bin\` shows the setup wizard with "refused the connection".

The app stores its data in `%LOCALAPPDATA%\WireTunnels` (configs encrypted with DPAPI for the current user,
`metadata\tunnels.json` in the macOS JSON shape, `logs\WireTunnels.log`). `WIRETUNNELS_TRACE_EXCEPTIONS=1` logs
every first-chance exception (diagnostics only).

Requires Windows 10 version 2004 or later. `PreUp/PostUp/PreDown/PostDown` are rejected, as on macOS.
