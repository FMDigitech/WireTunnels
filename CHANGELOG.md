# Changelog

This file tracks work in progress toward the next release and keeps the shipped ones as technical/QA reference. It's more detailed than the public release notes in `appcast.xml` — distill the "Public release notes (draft)" section of the unreleased version into `appcast.xml` once a build is actually signed and tagged.

## Unreleased

### Security
- **The helper installs the WireGuard tools itself** (issue #34, @tobikris). Previously the app picked the files and the helper copied them after checking hashes from a manifest in the same bundle. The app's checks could be raced, the hashes weren't anchored to anything the helper trusted, symlinks were followed, and `wg-quick` was never checked again after installation. Now the helper copies the tools only from its own app bundle into a staging folder only root can write, rejects anything that isn't a regular file, and checks each copy against anchors compiled into the helper: `wg` and `wireguard-go` must be signed by the app's team with their own identifier, and `wg-quick` must match the SHA-256 generated when the helper was built. `bin/` is replaced only when all three pass.
- **Tools are checked before every run.** The helper installs at start and whenever a check fails. Right before launching a tool it checks it again (all three for `wg-quick`, only `wg` for other `wg` commands). A tool that fails is replaced from the bundle and the event is logged as an error, both in the system log (`tool-installer` category) and in the app's log as `Helper: …`.

### Changes
- No more *Install Tools* / *Reinstall Tools* buttons. Approving the helper is enough; the setup wizard's second step is now *Prepare WireGuard Tools* with *Retry*, and connecting waits until the helper reports the tools ready.
- Settings > WireGuard Tools shows the bundled tools' provenance (versions, source, revisions, architectures). The "SHA256: valid" shield and "Last verified" time are gone: for bundled tools they compared each file with itself. "Binaries: Verified / Not Ready" shows the helper's actual result.

### Bug fixes
- An install interrupted by a helper restart no longer leaves a half-filled staging folder in `/Library/Application Support/WireTunnels`; the next install removes it.

### Build
- `Scripts/generate_tool_anchors.sh` runs before the helper compiles: it prepares the patched `wg-quick` (`build_wireguard_binaries.sh --prepare-wg-quick`) and compiles its hash into the helper. The app's copy step fails the build if the bundled `wg-quick` doesn't match.
- `wg` and `wireguard-go` are signed with an explicit identifier (`codesign` otherwise derived ones like `wg-55554944…`), and the signing identity is part of the tool cache key. The first build after updating rebuilds the tools once.

### Helper
- Protocol revision `inventory-routing-v2-helper-tools` (`installBundledTools` removed, `toolStatus` added): installed helpers are detected as stale and replaced on first launch.

### Known limitations / follow-ups
- Builds signed by another team, or ad-hoc, can't install the tools: the helper requires the team in `applicationTeamIdentifier`. Local test builds need their own team ID and bundle ID.
- Right after the helper is approved, the app may re-register it once, which stops the first install; the restarted helper installs again.
- Rebuilding without a version or protocol change doesn't restart a running helper; restart it with `sudo launchctl kickstart -k system/com.fmdigitech.WireTunnels.helper`.

### Public release notes (draft — for `appcast.xml` once this is actually built, signed, and tagged)

```html
<ul>
    <li>Security: the privileged helper now installs the WireGuard tools itself, only from the signed app, and checks them before every use; modified tools are replaced and logged</li>
    <li>No more Install Tools step: approving the helper is enough</li>
</ul>
<p><strong>Notes</strong></p>
<ul>
    <li>Existing installs will be prompted to update the privileged helper on first launch after upgrading</li>
</ul>
```

---

## 1.0.7 — released 2026-10-21

Integrates the community pull requests #9–#26 (thanks @007hacky007, @tobikris and @chocholom) and closes the open issues #6, #7 and #27. Per-app split tunneling (#5) is deferred to a later version.

### Security
- **wg-quick hook filter bypasses closed** (#25, @tobikris): crafted configurations could get past the hook filter and run commands as root through wg-quick. The filter now rejects those forms.

### New features
- **Inventory AllowedIPs** (#26, @chocholom): a personal tunnel can run a local command after connecting; the IPs/CIDRs it prints are validated (at least /8 for IPv4 and /32 for IPv6, no loopback, link-local, multicast or unspecified ranges), appended to the peer's static AllowedIPs and routed. The last inventory is cached; static and cached destinations stay blocked outside their VPN, also after disconnect or app quit. See `Scripts/INVENTORY.md`. Limits: personal single-peer tunnels, no bypass routes or hop chains.
- **Search Domains field** (issue #6): the new and edit tunnel forms have a separate *Search Domains* field. It is written to the same `DNS =` line, which wg-quick already applies as macOS search domains while the tunnel is up and restores on disconnect. Domains are validated; only real addresses are used as split-DNS nameservers.
- **Duplicate tunnel** (#10): context menu and detail page; the copy is disconnected and its On-Demand rules are off.
- **Passive feedback for automatic recovery** (#18): failed automatic connects stay in the log instead of opening an alert; the menu bar and menu show connecting / reconnecting / connection lost with *Retry* and *Details*.
- **Monochrome menu bar icon** (#16) and **automatic update-check setting** (#17).
- Menu bar menu closes on outside clicks and before opening windows (#14), explains a missing setup, and applies the Dock preference at launch (#24).

### Bug fixes
- **Kill switch now blocks traffic.** Its rules were loaded into a PF anchor that the system ruleset never evaluates, so enabling it had no effect. The rules now live under `com.apple/wiretunnels.killswitch` (evaluated by the standard `anchor "com.apple/*"`), the endpoint exception is limited to root-owned UDP and keeps PF state so the server's replies are accepted, and the old anchor is flushed. Verified live: with the kill switch on, traffic outside the tunnel is blocked while the tunnel keeps working, and quitting the app releases it.
- **Quit waits for tunnel cleanup** (#23): new connections are blocked while quitting, pending operations finish, tunnels are disconnected and re-checked, DNS and network settings are restored, and a failed cleanup offers *Retry* or *Cancel Quit*. Connect controls require installed, verified tools.
- **DNS** (#12): only the active network services are changed, every touched service is restored after a network switch, and a persistent journal repairs DNS left behind by an interrupted setup or a helper restart.
- **Sleep and wake** (#13, issue #27): helper timeouts count awake time only, so the error shown after opening the lid no longer appears.
- **Helper commands are bounded and traced** (#11): `wg-quick up` has a 20-second deadline with rollback, log lines carry timings, and private keys are redacted.
- **Tunnels are matched by their live runtime configs** (#9), so profiles sharing keys and endpoint keep separate status, traffic and disconnect paths.
- **Shared tunnel editor** (#19, issue #7): *Edit Config* loads the shared tunnel's configuration instead of an empty editor.
- Preserve tunnel display names (#20), protect saved tunnel metadata from corruption (#21), no On-Demand reconnects when opening tunnel details (#22), and no warning for a single full tunnel (#15).

### Helper
- Protocol revision `inventory-routing-v2` and version 1.0.7: installed helpers are detected as stale and replaced on first launch. The helper's launch daemon now has `RunAtLoad`, so saved inventory protection and DNS repair are restored at boot without waiting for the app.

### Known limitations / follow-ups
- DNS values left behind by older versions are restored as they are. If your services still point at a VPN-only DNS server while no tunnel is up, reset them in System Settings > Network > Details > DNS, or with `sudo networksetup -setdnsservers "<service>" Empty`.
- Enabling the kill switch now has an effect: traffic is blocked whenever its tunnel is not up.
- Inventory protection could not be tested end to end against a real server; it was verified with the real helper using documentation addresses.

### Public release notes (draft — for `appcast.xml` once this is actually built, signed, and tagged)

```html
<ul>
    <li>Kill switch fixed: it now really blocks traffic outside the tunnel while it is enabled</li>
    <li>Security: closed wg-quick hook filter bypasses that could run commands as root from a crafted configuration</li>
    <li>New: per-tunnel inventory command that adds discovered IPs/CIDRs to a tunnel's AllowedIPs and routes, and keeps them protected outside the VPN</li>
    <li>New: Search Domains field for tunnels, applied while connected and restored on disconnect</li>
    <li>New: duplicate a tunnel, monochrome menu bar icon and an automatic update-check setting</li>
    <li>Automatic reconnect failures no longer pop up alerts: the menu bar shows connecting, reconnecting or connection lost, with Retry and Details</li>
    <li>Quitting waits for tunnels to disconnect and DNS to be restored, and lets you retry or cancel if cleanup fails</li>
    <li>DNS only changes on the active network and is repaired after an interrupted setup</li>
    <li>Fixed the error shown after waking from sleep and an empty editor for shared tunnels</li>
    <li>The menu closes when you click elsewhere, tunnel names are preserved and saved metadata is protected from corruption</li>
</ul>
<p><strong>Notes</strong></p>
<ul>
    <li>Existing installs will be prompted to update the privileged helper on first launch after upgrading</li>
    <li>If you use the kill switch, traffic is now blocked whenever its tunnel is down; turn it off per tunnel if you do not want that</li>
    <li>If your DNS still points to a VPN-only server from an older version, reset it in System Settings &gt; Network &gt; Details &gt; DNS</li>
</ul>
```

---

## 1.0.6 — released 2026-10-09

Prompted by a user (James) testing the Shared Tunnels feature — see the three follow-up requests below.

### New features

#### Shared tunnels: admin-editable "User Access" (connect / disconnect) policy
- **Why:** `ManagedTunnelPolicy.usersCanConnect` / `usersCanDisconnect` were already stored and enforced (button disabling, `connectTunnel`/`disconnectTunnel` guards) but no UI ever let an administrator change them from the default (both allowed).
- **What:** administrators now see a "User Access" section on a shared tunnel's detail page with two toggles. Saved through the existing admin-authorized `updateManagedTunnel` XPC call, so no helper change was needed for this item.
- **Files:** `TunnelManager.updateManagedAccessPolicy(...)`, `TunnelDetailView.accessControlSection`.

#### "Start in Background" setting
- **Why:** the dashboard window was force-opened on every launch, including Launch at Login.
- **What:** new Settings > Behavior toggle (`launchInBackground`). When on, `MenuBarIconView` skips the automatic `openWindow(id: "dashboard")`; the window opens from the menu bar or a Dock click (`applicationShouldHandleReopen` now posts `.openDashboardRequested` when the window was never created). Applies to every launch, not only login launches. Pair with "Hide Dock icon" for a menu-bar-only app.
- **Files:** `WireTunnelsApp.swift`, `SettingsView.swift`.

#### Option to require an administrator to turn off "Launch at Login"
- **What:** administrators get a new Settings toggle. When enabled (stored root-owned in `/Library/Application Support/WireTunnels/managed/metadata/settings.json`, so standard users can't edit it), turning off Launch at Login — or resetting app data while it's on — prompts for administrator credentials via `AuthorizationServices`.
- **Limitation:** app-level only. A user can still remove the login item in System Settings > General > Login Items; a hard lock needs MDM. If the helper can't be reached, the gate fails open.
- **Helper protocol bumped** to `system-settings-v1` (new XPC methods `getSystemSettings` / `setSystemSettings`), so an installed older helper is detected as stale and the app prompts to reinstall it.
- **Files:** `HelperTool.swift`, both `WireguardHelperProtocol.swift` copies, `WireGuardCommandService.swift`, `TunnelManager.swift`, `SettingsView.swift`, `Models/Tunnel.swift`.

#### Split DNS (GitHub #2)
- **What:** personal tunnels get a "Split DNS" section: domains (e.g. `lan`, `corp.example`) whose lookups go to the tunnel's `DNS =` servers while everything else keeps the system DNS. Implemented as `/etc/resolver/<domain>` files written by the helper (`syncSplitDNS`), each carrying a `# Managed by WireTunnels` marker; resolver files without the marker are never modified or removed. When domains are set, the config is connected without `DNS =` (like multi-hop legs), so wg-quick doesn't set DNS system-wide.
- **Behaviour:** the full resolver set is re-synced on connect, disconnect, status refresh (tunnel dropped) and launch (flushes orphans). Adding the first domain to (or removing the last from) a connected tunnel offers to reconnect it, since the system-wide DNS is decided at connect time. Resolver ownership is per macOS user (`(uid N)` in the marker), so one user's sync never removes another's.
- **Protocol revision bumped** to `split-dns-v1` (new XPC method), so older helpers are replaced.
- **Shared tunnels:** the domains live in the tunnel's policy (administrator-only edit, validated by the helper); `stageManagedConfig` strips `DNS =` from the runtime copy when domains are set.
- **Files:** `HelperTool.swift`, both `WireguardHelperProtocol.swift`, `WireGuardCommandService.swift`, `TunnelManager.swift`, `Models/Tunnel.swift`, `TunnelDetailView.swift`; `Scripts/test_split_dns.sh`.

### Bug fixes

#### Tunnel names longer than 15 characters (GitHub #3)
- **Cause:** the 50-character display limit was advertised, but `ConfigStorageService.destinationURL` still rejected file names over 15 bytes (macOS interface-name limit).
- **Fix:** the display name (up to 50 chars) is kept on the tunnel; the config file gets `fileBaseName` — unchanged when it fits in 15 bytes, otherwise a prefix plus a stable FNV-1a hash suffix. Same algorithm in the helper (`ConfigName.fileBaseName`) for shared tunnels, which now keep the full name too. Editing/saving no longer depends on the name length; shared-tunnel updates refuse to overwrite another tunnel's file.

#### Clients sharing a server key and port shown as connected together (GitHub #4)
- **Cause:** `refreshStatus` matched live interfaces by server peer key + port only, so one interface could be assigned to several client profiles. `StatusMonitorService` also read the private-key column of `wg show dump` as the interface "public key".
- **Fix:** tunnels store `localPublicKey` (derived from their own `PrivateKey`, backfilled at launch) and only match an interface with the same key; an interface is assigned to at most one tunnel per pass, tunnels with a local key are matched first. The status parser now uses the real public-key column and the helper redacts private keys from the dump it returns.
- **Shared tunnels:** the root helper derives the client key from the root-owned config, stores it in the record (`localPublicKey`, backfilled on list) and the app matches on it like for personal tunnels.
- **Files:** `TunnelManager.swift`, `StatusMonitorService.swift`, `WireGuardConfigParser.swift` (`WireGuardKey`), `Tunnel.swift`, `HelperTool.swift`;.

---

### Known limitations / follow-ups
- The administrator-required Launch at Login gate is app-level only: a standard user can still remove the login item from System Settings > General > Login Items, since that panel is outside the app's control. A hard lock would need an MDM-managed Login Items configuration profile.
- "Start in Background" suppresses the dashboard window on every launch, not only a Launch at Login launch (there's no reliable way to tell the two apart from inside the app).

---

### Public release notes (draft — for `appcast.xml` once this is actually built, signed, and tagged)

```html
<ul>
    <li>Shared tunnels: administrators can now allow or block other users from connecting and/or disconnecting a shared tunnel, from the tunnel's own detail page</li>
    <li>New "Start in Background" setting: skip opening the dashboard window on launch (pairs well with "Hide Dock Icon" for a menu-bar-only app)</li>
    <li>New administrator option to require an admin password to turn off "Launch at Login"</li>
</ul>
<p><strong>Notes</strong></p>
<ul>
    <li>Existing installs will be prompted to update the privileged helper on first launch after upgrading</li>
    <li>The administrator Launch-at-Login option only governs WireTunnels' own Settings — it doesn't prevent disabling the login item from System Settings directly</li>
</ul>
```

*(Numbers/dates/signature to be filled in by the release workflow — see `.github/workflows/release.yml`, which auto-creates the versioned `<item>` on tag push but does not generate the `<description>`; that's added by hand, as done for every prior release.)*

<!-- Everything below this line shipped in 1.0.5 and is preserved in appcast.xml; kept here only as historical implementation detail. -->

### 1.0.5 — released 2026-08-31

#### Reconnect automatically when a peer's DDNS/dynamic-IP address changes
- **Why:** the DHCP fix below covers the client's own local IP changing under an active tunnel. There's a mirror-image gap on the server side: `wg-quick` resolves a config's `Endpoint =` hostname exactly once, at connect time. If the peer is a home server, self-hosted box, or anything behind DDNS and its public IP changes while the tunnel is still "connected," the kernel interface keeps sending to the stale address and the tunnel goes silently dead — same failure mode as the DHCP bug, just triggered from the other end. This is a well-known WireGuard-wide limitation (upstream ships an unofficial `contrib/reresolve-dns` script for it).
- **What it does:** roughly once a minute, for every active tunnel, `TunnelManager.checkEndpointReResolution()` re-reads the tunnel's config file, resolves its `Endpoint` hostname fresh, and compares that against the address `wg show` currently has live (frozen since connect). A literal-IP endpoint always re-resolves to itself, so static-IP tunnels never trigger anything. When they differ, only the affected tunnel(s) are restarted — `restartActiveTunnelInterfaces()` now takes an optional `onlyTunnelIDs` scope so an unrelated tunnel to a different peer isn't bounced (and doesn't trip its kill switch) for a DNS change that has nothing to do with it.
- **Files:** `WireTunnels/Services/TunnelManager.swift` — `checkEndpointReResolution()`, `restartActiveTunnelInterfaces(onlyTunnelIDs:)`, wired into the existing `startPolling()` loop at a ~60s cadence (separate from the 2s status poll, since it's a DNS lookup per active tunnel).

### Bug fixes

#### Active tunnel didn't reconnect after a DHCP lease renewal (dynamic IP)
- **Symptom reported:** on a network with a short/dynamic DHCP lease, when the local IP was renewed the tunnel stayed "Connected" in the UI but traffic broke, throwing an error. Manually disconnecting and reconnecting fixed it until the next renewal.
- **Root cause:** `NWPathMonitor`'s path handler does fire on a same-interface IP renewal, but `TunnelManager.handleNetworkChange()` — the only thing wired to it — only re-evaluates On-Demand connect/disconnect rules. It does nothing for a tunnel that's already active and whose On-Demand rule (if any) still matches, since nothing about the matched network changed. The tunnel's WireGuard socket stayed bound to the stale local address, unlike the system-wake path, which explicitly restarts active tunnels' interfaces (`reconnectAfterWake()`/`handleSystemWake()`).
- **Fix:** `NetworkMonitorService` now fingerprints the primary physical interface's own IPv4 address (via `getifaddrs`) on every path update and fires a new `onLocalAddressChange` callback when that address changes while the interface itself stays the same. `TunnelManager.handleLocalAddressChange()` reuses the same active-tunnel restart pass as system wake (factored out into `restartActiveTunnelInterfaces()`, with a reentrancy guard so a renewal detected around a wake doesn't double-restart), then falls through to the usual On-Demand re-evaluation.
- **Files:** `WireTunnels/Services/NetworkMonitorService.swift`, `WireTunnels/Services/TunnelManager.swift` — `handleLocalAddressChange()`, `restartActiveTunnelInterfaces()`.

#### Tunnels didn't reconnect or auto-connect/disconnect reliably after sleep
- **Symptom reported:** after the Mac woke from sleep, tunnels stayed "Connected" in the UI with dead traffic, and On-Demand (auto-connect/disconnect) rules didn't fire.
- **Root cause:** `TunnelManager.handleSystemWake()` already restarted tunnels that were active before sleep, but never re-ran `handleNetworkChange()` (the On-Demand evaluator). If the Mac woke on the same Wi-Fi network it slept on, `NWPathMonitor` never emits a fresh path update (no interface change to report), so On-Demand rules had no trigger to run at all after a wake.
- **Fix:** `handleSystemWake()` now calls `handleNetworkChange()` after reconnecting already-active tunnels, so On-Demand rules are always re-evaluated on wake regardless of whether the network path actually changed.
- **File:** `WireTunnels/Services/TunnelManager.swift` — `handleSystemWake()`.

#### Allowed IPs / peer data randomly swapped between tunnels
- **Symptom reported:** with several tunnels configured, reconnecting/disconnecting would occasionally cause a tunnel to show the wrong Allowed IPs, triggering a spurious "conflicting networks" warning. Manually disconnecting and reconnecting the affected tunnel fixed it until the next occurrence.
- **Root cause:** `refreshStatus()` matched a `wg show` interface back to a `Tunnel` primarily by a previously-learned kernel `utunN` device name. On macOS, utun numbers are assigned "first free slot" at interface creation — they are **not** pinned to a particular tunnel and can be reassigned to a different tunnel the next time interfaces come up, especially when multiple tunnels are torn down and restarted around the same time (e.g. during the wake-reconnect pass above, which could tear down two tunnels' interfaces before either one came back up, freeing both utun slots at once). When a stale name got reassigned to a different tunnel, `refreshStatus()` silently attributed that tunnel's peer data (including Allowed IPs) to the wrong `Tunnel` model.
- **Fix:** the interface-name match is now only trusted after confirming the interface's peer public key actually belongs to that tunnel; if it doesn't (or the name isn't found), the code falls back to searching all interfaces by peer public key, which is what actually identifies a tunnel — not a kernel-assigned name that can be reassigned to someone else.
- **File:** `WireTunnels/Services/TunnelManager.swift` — `refreshStatus()`.

#### Connecting one tunnel could mark a second, unrelated tunnel as connected too, with a spurious "Overlapping Routes" warning
- **Reported by a user:** two tunnels ("Emcdata", endpoint `x.x.x.x:443`, and "KION", endpoint `x.x.x.x:4443`) with disjoint AllowedIPs — same server IP, different ports. Connecting either one alone also showed the other as connected, with `updateWarnings()` reporting overlapping AllowedIPs between them even though their configs don't overlap at all.
- **Root cause:** the peer-public-key fallback added by the fix above (necessary because utun names get reassigned) assumes a peer public key uniquely identifies one tunnel. That doesn't hold when a server operator reuses the same WireGuard keypair across multiple listening ports to front separate configs for different services/tiers — exactly this user's setup. With only one of the two connected, `refreshStatus()`'s public-key search matched the *other*, disconnected tunnel's model to the live interface as well (same peer key), marking it active and overwriting its `allowedIPs` with the live peer's actual AllowedIPs — which is also why the two then looked "overlapping": one tunnel's displayed AllowedIPs had literally been clobbered with the other's at runtime.
- **Fix:** the public-key match (both the by-name check and the full fallback search) now also requires the live peer's endpoint port (from `wg show`) to match the port in the tunnel's own configured `Endpoint =` value, via the existing `parseEndpoint()` helper. Two tunnels sharing a peer public key but differing only by port are now correctly told apart; when a tunnel's endpoint/port isn't resolvable, matching quietly falls back to public-key-only as before.
- **File:** `WireTunnels/Services/TunnelManager.swift` — `refreshStatus()`.

#### Kill switch toggle silently re-saved and re-armed itself on every view appearance
- **Found while QA-testing multi-hop:** the log showed several repeated `Kill switch updated for <tunnel>: enabled=true` entries seconds apart, without the user touching the toggle.
- **Root cause:** `TunnelDetailView`'s kill-switch `Toggle` used `.onChange(of: killSwitchEnabled) { saveKillSwitch() }`. That `onChange` fires whenever the local `@State` value changes for *any* reason — including `onAppear`/`onChange(of: live.isKillSwitchEnabled)` merely syncing the local UI state from what's already persisted. So every time the tunnel's detail view was freshly mounted for a tunnel that already had the kill switch on, the sync (default `false` → persisted `true`) was indistinguishable from a real user toggle, and silently re-saved and re-armed it. Harmless in effect (same value, idempotent), but wasteful (redundant privileged XPC calls, log spam).
- **Fix:** the `Toggle` now uses an explicit `Binding` whose `set` closure both updates the local state and calls `saveKillSwitch()` — so only a genuine user interaction with the toggle saves; programmatic syncs from persisted state no longer do.
- **File:** `WireTunnels/Views/Dashboard/TunnelDetailView.swift` — kill switch `Toggle`.
- **Note:** pre-existing bug, not introduced by the new features below. The equivalent state-sync code added for the new speed-test-URL field and split-tunnel-exclusions list was written to only save on explicit user actions (submit/add/remove), so neither is affected by this same class of bug.

#### A disconnected multi-hop chain still blocked connecting its tunnels individually
- **Found while QA-testing multi-hop:** after disconnecting a chain (both tunnels down), trying to connect either tunnel individually still failed with *"...is part of a multi-hop chain; connect or disconnect the chain instead."*, even though nothing was actually active or at risk.
- **Root cause:** `connectTunnel`/`disconnectTunnel` blocked manual actions based on `chain(containing:)`, which only checks whether a chain *pairing* exists (`HopChain.isEnabled`) — not whether that chain is actually connected. Since pairing a tunnel never gets un-set, this blocked the tunnels permanently, whether or not the chain was ever brought up.
- **First fix attempt was incomplete:** added `activeOrBusyChain(containing:)`, treating a chain as active when *either* leg was connected. This let a lone member connect individually again, but then immediately trapped it: with one leg now active, `activeOrBusyChain` read that as "the chain is active" and blocked disconnecting that same tunnel — connect worked, disconnect never would, short of finding the chain's own disconnect control.
- **Actual fix:** `activeOrBusyChain` now requires *both* legs active (or the chain mid-connect/disconnect) before treating it as an established chain. Connecting/disconnecting a lone member is allowed in every state except a genuinely fully-up chain. (`chain(containing:)` itself is unchanged and still correctly used for chain-pairing exclusivity, where "is this tunnel paired at all" is the right question.)
- **File:** `WireTunnels/Services/TunnelManager.swift` — `connectTunnel()`, `disconnectTunnel()`, `activeOrBusyChain(containing:)`.

#### Multi-hop chain left a stale VPN DNS server in System Settings after disconnecting
- **Symptom reported:** after disconnecting a multi-hop chain (or just its exit leg), the DNS server shown in System Settings > Network > [service] > DNS stayed on a VPN address instead of reverting to the real network's DNS.
- **Root cause:** verified with a scripted harness that mocks `networksetup` end to end. macOS wg-quick's DNS handling snapshots whatever `networksetup -getdnsservers` currently reports as the "pre-tunnel" baseline, to restore on disconnect. With both hop and exit applying DNS to the same network service in sequence (hop connects first, exit second), the exit's snapshot captured the hop's *already-VPN* DNS instead of the real one — so disconnecting the exit "restored" DNS to the hop's address, not the real one, until the hop also disconnected.
- **Fix:** the hop leg of a chain no longer touches system DNS at all — its `DNS =` line is stripped from the staged runtime config before `wg-quick up` runs. The hop is a pure relay (the exit's endpoint is already resolved to a literal IP before the chain connects, see `exitRouteEntry`), so it never needed to manage DNS; only the exit tunnel now touches system DNS in a chain, which removes the nested-snapshot problem entirely. Re-verified with the same mock harness after the fix: disconnecting now correctly restores the real DNS.
- **File:** `WireTunnels/Services/TunnelManager.swift` — new `connectTunnel(..., suppressSystemDNS:)` parameter and `writeConfigWithoutDNS(from:)`, used by `connectHopChain()` for the hop leg.

#### On-Demand auto-disconnect tore down an individually-connected chain member as if it were the whole chain
- **Symptom reported (with log):** with only the hop tunnel connected individually (allowed by the fix above), the next On-Demand evaluation logged *"Auto-disconnect rule triggered for hop chain X"* and disconnected it — even though the user had only connected one tunnel, never "the chain."
- **Root cause:** `handleNetworkChange()`'s hop-chain loop computed chain activity the same either-leg-active way as the bug above, so a lone individually-active hop was indistinguishable from a fully-established chain and got torn down via `disconnectHopChain` the next time the hop's own network rule matched "disconnect."
- **Fix:** the auto-disconnect branches now require both legs active before calling `disconnectHopChain`; the auto-connect branch keeps its original either-active guard, since `connectHopChain` already rejects connecting on top of a partially-up chain on its own.
- **File:** `WireTunnels/Services/TunnelManager.swift` — `handleNetworkChange()`.

#### Multi-hop's On-Demand design changed: a chain member's rule no longer cascades into the whole chain
- **Reported during QA:** a hop tunnel's own On-Demand auto-connect rule was, by design, also acting as "the chain's" trigger — matching the connect network brought up *both* hop and exit, not just the tunnel the rule was configured on. This was surprising and undesired: a tunnel's own rule should only ever govern that tunnel.
- **Change:** removed the hop-chain loop from `handleNetworkChange()` entirely. Every tunnel, including chain members, now evaluates only its own On-Demand rule and connects/disconnects only itself. Multi-hop chains are connected/disconnected as a unit exclusively through the explicit controls in `HopChainView` — there is no automatic chain-wide trigger anymore.
- **File:** `WireTunnels/Services/TunnelManager.swift` — `handleNetworkChange()`.

#### Multi-hop's host route didn't survive sleep/wake
- **Found while QA-testing multi-hop on real hardware:** with an active chain, put the Mac to sleep and woke it — both tunnels correctly reconnected (confirmed via log and `wg show`), but `netstat -rn`/`route -n get` showed the exit tunnel's endpoint had fallen back to the normal default route, instead of still pointing at the hop's interface.
- **Root cause:** `reconnectAfterWake` tears down and recreates the hop's utun interface during the wake-restart (same name, e.g. `utun6`, but a new kernel object) — and the kernel silently drops any route that was bound to the old one. `reconnectHopChainAfterWake` re-derived the *same* `RouteEntry` (identical cidr/interface string) and asked the helper to sync it, but the helper's diff-based `syncRoutes` compares the request against what it remembers previously installing for that chain, sees no difference, and skips re-issuing `route add` — with no visibility into whether the kernel actually still has that route or dropped it silently. Net effect: the route stayed lost after every sleep/wake with an active chain, without any error being logged.
- **Fix:** `reconnectHopChainAfterWake` now flushes the chain's routes (empty entries) before reapplying the real entry, forcing a genuine `route add` regardless of what the helper's in-memory tracker believes is already installed. Also added the error logging this function was missing, so a real failure here is visible in the log instead of silently swallowed.
- **File:** `WireTunnels/Services/TunnelManager.swift` — `reconnectHopChainAfterWake()`.
- **Known residual risk, not fixed here:** the same theoretical gap exists in `syncExcludedRoutes` (#3)'s wake-resync path if a future change ever pointed an exclusion route at a utun interface instead of the physical gateway — today exclusions only ever target the physical gateway/interface, which doesn't get torn down across sleep the way a WireGuard utun does, so this hasn't been observed in practice. Worth the same flush-then-reapply treatment if that assumption ever changes.

#### Every rebuild forced a spurious "Reinstall Tools" prompt, even with no source changes
- **Reported:** every new build/update required "Install Tools"/"Reinstall Tools" in Settings to make the app work again, even though the tools already showed as installed.
- **Root cause:** `Scripts/build_wireguard_binaries.sh` caches the built (unsigned) `wg`/`wg-quick`/`wireguard-go` binaries and skips recompiling them when the pinned WireGuard revisions haven't changed — but it re-signed `wg` and `wireguard-go` with `codesign --force` on *every* build regardless of cache hit, copying fresh into the app bundle before computing the manifest's sha256 hashes. `codesign` isn't byte-for-byte deterministic across separate invocations even for identical input with the same identity, so the bundled manifest's hashes for those two binaries drifted on every single rebuild — making `WireGuardToolLocator.bundledBinariesMatchInstalled()` report a mismatch and forcing a reinstall each time, independent of whether the actual WireGuard binaries had changed at all. Verified directly: comparing the installed manifest against a freshly-built one showed `wg`/`wireguard-go` hashes differing every time, while `wg-quick` (a plain script, never signed) matched exactly.
- **Fix:** signing now happens once, inside the cache-populating build path (`build_wireguard_go`/`build_wireguard_tools`, i.e. only on an actual cache miss), and the already-signed cached copy is what gets reused on every later build. `copy_to_bundle` no longer re-signs. Verified by building twice in a row and diffing the bundled `wg`/`wireguard-go` hashes — now identical across rebuilds instead of changing every time.
- **File:** `Scripts/build_wireguard_binaries.sh` — new `sign_cached_binary()`, called from `build_wireguard_go()`/`build_wireguard_tools()`; signing loop removed from `copy_to_bundle()`.
- **One-time local fixup needed:** the pre-existing local build cache (from before this fix) held unsigned binaries; it was re-signed in place once to bring it in line with the new invariant (cache always holds signed binaries) without forcing a full from-source rebuild.

#### Release/Archive build failed to compile: actor-isolation errors in `PingService`/`ThroughputProbeService`
- **Found via a real Xcode Archive (Release configuration) build**, not caught by this session's Debug builds. Both files declare `nonisolated static func` methods that read `private static let` constants — under the project's MainActor-by-default isolation setting, those constants are MainActor-isolated unless stated otherwise, and reading them from a `nonisolated` function is a hard actor-isolation error. Debug's build settings didn't surface this; a Release/Archive build did.
- **Fix:** marked the constants (`PingService.timeRegex`, `ThroughputProbeService.maxBytes`/`defaultTimeout`) `nonisolated` themselves, since they're plain immutable values never mutated and safe to read from any isolation context.
- **Files:** `WireTunnels/Services/PingService.swift`, `WireTunnels/Services/ThroughputProbeService.swift`.
- **Note:** `PingService`'s version of this bug pre-dates this session's changes — it wasn't introduced by the new features, just exposed by finally running a Release build. Verified fixed in both Debug and Release configurations.

#### Tunnel name was silently truncated to 15 characters
- **Symptom reported:** a longer, descriptive tunnel name got cut short on save with no warning.
- **Root cause:** `ConfigStorageService.sanitize(name:)` capped the sanitized name at `prefix(15)` — an overly conservative leftover from treating the name as a raw kernel interface name; wg-quick/the kernel accept much longer interface names in practice.
- **Fix:** raised the cap to 50 characters.
- **File:** `WireTunnels/Services/ConfigStorageService.swift` — `sanitize(name:)`.

#### Shared (managed) tunnels couldn't be edited by anyone, including the administrator who created them
- **Symptom reported:** once a tunnel was shared with all users via "Make Shared," its name/config could no longer be edited — not even by an administrator. "Replace Managed Config" (swap the whole file) was the only available workaround.
- **Root cause:** `TunnelManager.updateTunnel()` unconditionally rejected any tunnel with `scope != .personal`, with no admin bypass — unlike the equivalent managed kill-switch/on-demand-rule update paths, which already gate on `currentUserIsAdministrator` and then go through the privileged helper (itself requiring real macOS admin authorization).
- **Fix:** `updateTunnel()` now follows that same existing pattern for managed tunnels — it checks `currentUserIsAdministrator`, then routes the edit through `commandService.updateManagedTunnel(...)`, the same authorization-gated path already used elsewhere. The "Edit Config" button is now also shown for shared tunnels, visible only to administrators.
- **Files:** `WireTunnels/Services/TunnelManager.swift` — `updateTunnel()`; `WireTunnels/Views/Dashboard/TunnelDetailView.swift` — `actionsSection`.

---

### New features

#### 1. Tunnel throughput / speed test
Sparkline throughput graphs already existed in the row, menu bar, and detail views (fed by `TunnelManager.trafficHistory`) — no changes there. Added the other half: an opt-in, **no built-in default host** throughput probe alongside the existing latency-only "Test Connection".
- New optional per-tunnel field `speedTestURL` (`Tunnel.swift`) — a user-supplied HTTPS URL. Left empty (the default), the throughput probe never runs and makes no network call, consistent with the app's no-telemetry / no-third-party-host design.
- New `ThroughputProbeService` (`WireTunnels/Services/ThroughputProbeService.swift`) — times a capped download (max 20 MB or 8s, whichever first) against the user's URL and reports Mbps.
- `TunnelManager.testConnection(for:)` now returns latency **and**, if a `speedTestURL` is configured, throughput in one call.
- UI: `TunnelDetailView` gained an editable "Speed test URL" field next to the existing Test Connection button; the result line now reads e.g. `42 ms avg, 87.3 Mbps` when throughput is available.

#### 2. Shortcuts (Siri / Raycast) support
Entirely new — the app had no App Intents, CLI entry point, or URL scheme before this.
- New `WireTunnels/Intents/` group: `TunnelEntity` (+ `EntityQuery` so Shortcuts can pick a tunnel by name), `ConnectTunnelIntent`, `DisconnectTunnelIntent`, `DisconnectAllTunnelsIntent`, `ConnectedTunnelsStatusIntent`, and `WireTunnelsShortcuts` (the `AppShortcutsProvider` that makes these discoverable in Shortcuts/Siri without the user building a Shortcut from scratch first).
- New `AppIntentBridge` (`WireTunnels/Services/AppIntentBridge.swift`) gives intents access to the app's single running `TunnelManager`. **Known limitation:** since there's no background daemon owning tunnel state, an intent can only act while WireTunnels is actually running; if it isn't, the intent surfaces a clear "WireTunnels is still starting" error rather than silently doing nothing.
- Raycast reaches these natively through its own "Run Shortcut" bridge — no Raycast-specific code was needed or added.
- `WireTunnelsApp.swift` sets `AppIntentBridge.tunnelManager` once at launch.

#### 3. Split tunnel exclusions (runtime, route-based)
New per-tunnel ability to exclude specific CIDR ranges from an already-connected tunnel at runtime — the traffic goes out the regular connection instead, without editing the config or reconnecting.
- New optional per-tunnel field `excludedRoutes: [String]` (`Tunnel.swift`).
- New `DefaultRouteService` (`WireTunnels/Services/DefaultRouteService.swift`) — unprivileged `route -n get default` shellout to find the current gateway/interface fresh every time (never cached, since Wi-Fi/Ethernet switches change it).
- New privileged XPC primitive `syncRoutes(ownerId:entries:)`, added to **both** copies of `WireguardHelperProtocol.swift` (`WireTunnels/Helpers/XPC/` and `WireTunnelsHelper/`, which must stay identical) and implemented in `WireTunnelsHelper/HelperTool.swift`. It validates every CIDR/gateway/interface server-side, diffs against what was previously installed for the same owner, and issues precise `route add`/`route delete` calls — mirroring the existing kill-switch's validate-then-resync pattern, but scoped per-owner instead of one shared PF anchor (since different tunnels'/chains' routes must not clobber each other).
- `TunnelManager` installs/flushes exclusion routes on connect, disconnect, live edits, and after a sleep/wake reconnect (gateway/interface can change across sleep, same reasoning as the existing kill-switch re-arm).
- UI: new "Split Tunnel Exclusions" section in `TunnelDetailView` (personal tunnels only — not exposed for shared/managed tunnels in this pass).
- **Helper protocol revision bumped** from `kill-switch-v1` to `route-sync-v1` (`WireGuardCommandService.swift` / `HelperTool.swift`) since this adds a new required XPC method — an already-installed helper predating this release will be detected as stale and the app will prompt to reinstall it (requires the app to be running from `/Applications`, per the existing installed-app safeguard).

#### 4. Multi-hop / chained tunnels
New client-side multi-hop: pairs two personal tunnels so one ("hop") is brought up first, and the other's ("exit") own WireGuard traffic is routed through the hop's interface via a host route — so the exit server sees the hop's IP, not the real one. Built entirely on top of #3's `syncRoutes` primitive; no new helper code. Does not touch the config parser or add multi-peer support (both the app's parser and the helper's config sanitizer still intentionally support only one `[Peer]` per config).
- New model `HopChain` (`WireTunnels/Models/HopChain.swift`) and `HopChainRepository` (`WireTunnels/Services/HopChainRepository.swift`, persisted to `hopChains.json`, mirrors `TunnelRepository`).
- `TunnelManager` gained `connectHopChain`/`disconnectHopChain` (hop up → resolve exit's endpoint to a literal IP → install host route through the hop's interface → exit up; reverse order to disconnect, with rollback on any failed step) and `reconnectHopChainAfterWake` (re-derives the host route after a wake restart, since interface names can change).
- A chain is connected/disconnected as a unit only through the explicit controls in `HopChainView` — there is no On-Demand automation of the chain itself. Each member tunnel's own On-Demand rule continues to govern only that tunnel (see the "On-Demand design changed" fix above); `handleSystemWake()` reconnects any tunnel that was active before sleep exactly as it would for a standalone tunnel, then additionally calls `reconnectHopChainAfterWake()` for each enabled chain to re-derive its host route (interface names can change across a wake restart). `stopAllActive()` disconnects chains before individual tunnels so app-quit never tears down a hop while the exit still depends on it. Manually connecting/disconnecting a chain-member tunnel from the normal tunnel list is only blocked while the chain is genuinely fully connected (or mid-connect/disconnect) — see the trap fix above.
- UI: new "Multi-Hop" sidebar section (`WireTunnels/Views/Dashboard/HopChainView.swift`) to pair two personal tunnels and connect/disconnect the chain. **Not done:** a visual "this tunnel is part of a chain" indicator on the tunnel row/list (optional polish, deferred).

---

### Deferred (not in this release)

#### Per-app split tunneling (Network Extension)
Explicitly out of scope for this pass, by decision: it requires a `NEPacketTunnelProvider` system-extension target, a `com.apple.developer.networking.networkextension` entitlement that only Apple can grant (formal request, timeline not under our control), and a fundamentally different runtime architecture than the current wg-quick + privileged-helper model. Treated as a separate, future-scoped initiative.

---

### Known limitations / follow-ups
- Split tunnel exclusions are personal-tunnel-only; shared/managed tunnels don't expose the field or an admin-controlled equivalent yet.
- No visual chain-membership indicator in the tunnel list/row.
- `updateWarnings()`'s overlap detection still does exact-string Allowed IPs comparison (pre-existing behavior, unchanged) — it doesn't reason about excluded routes or real CIDR containment.
- A helper crash/relaunch loses the in-memory route-tracking state (which owner has which routes installed); this can leave a stale route in the kernel table until the owning tunnel/chain's next disconnect resyncs with an empty list. Accepted for v1.
- Route/PF-touching and multi-hop changes are real kernel-routing-table and real-network behavior — not meaningfully unit-testable; they need manual QA on an actual Mac with real tunnels (see testing checklist discussed separately).

*(1.0.5's own public release notes are already published in `appcast.xml`'s "Version 1.0.5" item — not repeated here.)*
