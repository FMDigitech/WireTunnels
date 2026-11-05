# WireTunnels for Windows

Native Windows port of WireTunnels. Architecture: [`../docs/WINDOWS_PORT_ARCHITECTURE.md`](../docs/WINDOWS_PORT_ARCHITECTURE.md).
Next phases, step by step: [`NEXT_STEPS.md`](NEXT_STEPS.md).

## Layout

| Project | Role |
|---|---|
| `src/WireTunnels.Core` | Platform-neutral logic: models (same JSON as macOS `tunnels.json`), `.conf` parser and validation, DNS, IP prefixes, on-demand matching, warnings, recoverable JSON store, X25519 keys |
| `src/WireTunnels.Contracts` | Named-pipe protocol (framing, operations, DTOs) and `ServiceClient` |
| `src/WireTunnels.Service` | Windows Service (LocalSystem): pipe server with per-user authorization, wireguard-nt adapters, addresses, routes, metric/MTU, DNS |
| `src/WireTunnels.Cli` | `wiretunnels.exe connect / disconnect / status / genkey` |
| `tests/*` | xUnit; run on any OS (`dotnet test`) |

Not yet implemented (see the plan in the architecture doc): WinUI 3 app, kill switch (WFP), split DNS (NRPT),
excluded routes, multi-hop, managed shared tunnels, session/logoff handling, installer, updater.

## Build and test

Requires the .NET 8 SDK.

```powershell
dotnet test
dotnet publish src/WireTunnels.Service -c Release -r win-x64 --self-contained -o out
dotnet publish src/WireTunnels.Cli     -c Release -r win-x64 --self-contained -o out
```

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
4. As a normal user:
   ```powershell
   & "C:\Program Files\WireTunnels\wiretunnels.exe" connect C:\path\office.conf
   & "C:\Program Files\WireTunnels\wiretunnels.exe" status
   & "C:\Program Files\WireTunnels\wiretunnels.exe" disconnect office
   ```

Requires Windows 10 version 2004 or later. `PreUp/PostUp/PreDown/PostDown` are rejected, as on macOS.
