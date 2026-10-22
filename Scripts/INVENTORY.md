# Inventory AllowedIPs

WireTunnels can run a local inventory command after a personal tunnel connects,
then append its IP addresses/CIDRs to the saved configuration's static AllowedIPs
and install the additional routes on that tunnel. The command runs as your normal
user. Only the validated routing update goes through the privileged helper.

Disconnect the tunnel, open its **Inventory AllowedIPs** section, and set:

- **Executable:** your Python 3 executable's absolute path.
- **Arguments:** the absolute path to `server_ips.py`, your inventory URL, and
  optionally `--merge`, with each argument on a separate line.

For example, the arguments could be:

```text
/Users/you/bin/server_ips.py
https://inventory.example.com/servers.json
--merge
```

Click **Save Command**, then connect. The initial fixed AllowedIPs must reach the
inventory service, including its DNS server if needed. Cached inventory is applied
before fetching a fresh list; **Refresh Now** repeats the command while connected.
The saved `.conf` stays the source of the static prefixes and is not rewritten.
Live AllowedIPs, extra routes, and the last successful inventory are updated
together. A failed command keeps the last good inventory and reports an error.

Static and cached destinations are blocked outside their designated VPN by PF,
including during refresh, disconnect, and app quit. Protection remains installed
until **Disable and Remove Protection** is selected while disconnected. The helper
restores blocked policies when it starts at system boot. This is not a pre-boot
firewall: there can be a boot interval before the helper starts. Addresses never
seen before cannot be blocked in advance unless covered by a static prefix.
Only root-owned UDP traffic to the VPN endpoint is exempt, so the helper's
WireGuard transport can reconnect without allowing ordinary apps to bypass it.
The helper watches interface changes even after the app quits. A missing interface,
changed WireGuard identity, or reused interface name closes the VPN exception.

Use the standard macOS `com.apple/*` PF filter anchor. A missing anchor is an error;
WireTunnels does not replace the system firewall configuration. Custom firewall
rules or another administrator changing PF can interfere with protection. Inventory
commands currently support personal, single-peer tunnels, without bypass routes or
hop chains. Different inventory tunnels must have disjoint protected destinations.
The updated app requires its matching updated helper.

Both PF anchors sit directly under the standard `com.apple/*` wildcard, which
evaluates them in name order: `com.apple/wiretunnels.inventory`, then
`com.apple/wiretunnels.killswitch`. Inventory uses quick blocks on the wrong
interface; its verified VPN path falls through to the kill switch. It never uses
a quick VPN pass, so another tunnel's pass cannot override an inventory block,
and inventory cannot bypass the kill switch's choice of VPN. Endpoint exceptions
are root-only and create no PF state. Kill-switch synchronization clears its old
anchor after loading the replacement. Earlier custom quick passes in the root
ruleset can still bypass these anchors and are outside the supported setup.

The helper starts at boot (`RunAtLoad`) to restore saved blocks and watch interface
changes without waiting for the app. Restoring only on the next app launch would
leave cached destinations unprotected until then. With no policies, it installs
no inventory rules. App and helper must report the same protocol revision, so
they must ship together, with helper approval coordinated for the release.

Settings saves, connect, disconnect, and wake reconnect cannot modify the same
tunnel at once. A busy disconnect now reports an error and can be retried after
the operation finishes; an inventory fetch itself can be cancelled immediately.
Reset removes root-owned inventory policies before deleting local metadata. It
stops if that removal fails, preserving the tunnel IDs needed to remove protection.

Commands execute directly with an argument array, without an implicit shell. Output
must be nonempty IPs/CIDRs separated by whitespace or commas. Every entry is checked
before application. Limits are 60 seconds, 8 MiB of stdout, and 100,000 entries.
Discovered IPv4 prefixes must be /8 or longer; IPv6 prefixes must be /32 or longer.
Unspecified, loopback, link-local, multicast, and IPv4-mapped IPv6 ranges are
rejected. These limits apply to discovered output; static AllowedIPs stay explicit.
Disconnect cancels an in-progress fetch. The helper rejects results from an older
connection generation and never runs the inventory command itself.

## Python example

`server_ips.py` uses Python 3's standard library to turn a JSON server inventory
into IP addresses or exact CIDR ranges suitable for preparing `AllowedIPs`.
Supply your own inventory URL; the hostname below is a placeholder.

```sh
# One IP per line, preserving input order, duplicates and IPv6 spelling.
python3 Scripts/server_ips.py https://inventory.example.com/servers.json

# Deduplicate and merge into the largest CIDRs covering exactly the input IPs.
python3 Scripts/server_ips.py https://inventory.example.com/servers.json --merge
```

The inventory must be a JSON object whose values are server records. Each record
must have an `ip_all` string containing comma-separated IPv4 and/or IPv6 addresses.
Empty strings are allowed. See [examples/servers.json](examples/servers.json) for
a complete example using documentation-only addresses.

Run the bundled example locally from the repository root:

```sh
python3 Scripts/server_ips.py "file://$PWD/Scripts/examples/servers.json" --merge
```

Expected output:

```text
192.0.2.4/30
2001:db8::2/127
```

Merged output is sorted with IPv4 before IPv6. Aggregation never fills gaps or
includes addresses absent from the inventory. Isolated addresses become `/32`
or `/128` prefixes.

The script validates the entire inventory before writing output. Missing fields,
invalid or scoped addresses, empty inventories and fetch failures produce an error
on stderr and exit status 1. Network operations use a 30-second socket timeout.
Automation should check the exit status and retain its last good inventory on
failure; the app integration above does this automatically.

Run the regression tests from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_server_ips.py' -v
bash Tests/test_inventory_routing.sh
```

The Swift tests run the real tunnel manager against a fake XPC helper, including
connect, disconnect, wake, delayed settings replies, and missing configuration.
Helper tests inject PF, WireGuard and route operations and cover rollback, interface
reuse, exact route ownership, state cleanup, anchor ordering and 10,000 addresses.
They do not change the host's firewall, routes, or VPN connections. A signed
app/helper test on a disposable Mac
is still needed to verify live PF, WireGuard, and reconnect behavior. The current
upstream `main` also needs the missing bundled-tool build scripts supplied by PR #8
before a normal complete app build can run.
