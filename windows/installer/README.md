# WireTunnels for Windows — installer and updates (phase 7)

`release.ps1` does everything: runs the tests, publishes the service, CLI and app (self-contained) for x64 and ARM64,
adds the pinned `wireguard.dll`, signs, builds `WireTunnels-<version>-<arch>.msi` (WiX 5, `Package.wxs`) and can add
the signed items to `appcast-windows.xml`. The version lives in `../Directory.Build.props`.

```powershell
.\release.ps1 -Arch x64                    # unsigned local build -> ..\artifacts\WireTunnels-1.0.0-x64.msi
$env:WIRETUNNELS_ED25519_KEY = '<base64 private key>'
.\release.ps1 -SigntoolArgs '/sha1 <thumbprint> /fd sha256 /tr http://timestamp.digicert.com /td sha256' `
  -Appcast ..\..\appcast-windows.xml -DownloadBase https://github.com/FMDigitech/WireTunnels/releases/download/win-v1.0.0 -NotesFile notes.html
```

## What the MSI does
- Per-machine, `C:\Program Files\WireTunnels` (the service only accepts the app and CLI from there).
- Installs and starts the `WireTunnels` service (LocalSystem, automatic, depends on BFE, restarted by the SCM after a crash).
- Registers `wiretunnels://` links and an "Open with > Import with WireTunnels" entry for `.conf` files (never the default app), and a Start menu shortcut.
- Upgrades in place (same UpgradeCode); the running app is closed. Downgrades are refused.
- Uninstall runs `WireTunnels.Service.exe --cleanup`: removes the persistent kill switch and inventory firewall filters and
  `%ProgramData%\WireTunnels` (inventory policies **and shared tunnels**). An upgrade does not.
- Per-user data (`%LOCALAPPDATA%\WireTunnels`) and the `HKCU` Run entry are left alone, as with an app that is removed on macOS.

## Signing
One certificate for every `WireTunnels*.exe/dll`, `wiretunnels.exe` and the MSI (`-SigntoolArgs`: a certificate in the
store, EV token or Azure Trusted Signing's dlib). `wireguard.dll` keeps WireGuard LLC's signature; the service checks it.
The updater accepts an MSI only if its Authenticode subject equals `UpdateService.DefaultPublisher` ("FMDigitech"):
**set it to the real subject of your certificate** before the first release.

## Updates
The app reads `appcast-windows.xml` (`UpdateService.DefaultFeed`), picks the newest item whose `sparkle:os` is
`windows-x64`/`windows-arm64`, downloads the MSI, and installs it only if both checks pass: the Ed25519 signature (Sparkle's
`sign_update` format, key `UpdateService.DefaultPublicKey`) and the Authenticode publisher. Then `msiexec /i /passive` runs
through UAC and the app quits. The default public key is the one of the macOS feed: export its private half from the Mac
(`generate_keys -x`) into `WIRETUNNELS_ED25519_KEY`, or make a separate Windows key with
`dotnet run --project ..\tools\WireTunnels.SignUpdate -- keygen` and put its public half in `DefaultPublicKey`.

## Release checklist
1. Bump `Version` in `Directory.Build.props`; `dotnet test` green (release.ps1 runs it).
2. `release.ps1` for x64 and arm64 with signing and `-Appcast`; check `signtool verify /pa /all` on the MSIs.
3. Clean Windows 10 2004 and Windows 11, x64 and ARM64: install, connect a tunnel, upgrade from the previous MSI (tunnel
   data kept, service restarted), uninstall (no WireTunnels service, adapters, filters or `%ProgramData%\WireTunnels`).
4. Upload the MSIs to the release, commit the appcast.
