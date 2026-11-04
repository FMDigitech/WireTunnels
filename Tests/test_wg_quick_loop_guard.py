#!/usr/bin/env python3
"""Check that wg-quick cannot route wireguard-go's own packets back into the tunnel."""
from pathlib import Path
import subprocess
import tempfile
import sys

from wg_quick_fixture import load_source

ROOT = Path(__file__).resolve().parent.parent
PATCHES = ['wg-quick-bash3.patch', 'wg-quick-dns-cleanup.patch', 'wg-quick-cleanup.patch',
           'wg-quick-active-dns.patch', 'wg-quick-dns-recovery.patch']

FAKES = r'''
auto_su() { :; }
detect_launchd() { unset LAUNCHED_BY_LAUNCHD; }
get_real_interface() { return 1; }
add_if() { REAL_INTERFACE=utun99; }
set_config() { :; }
add_addr() { :; }
set_mtu() { :; }
up_if() { printf 'up\n' >> "$TEST_EVENTS"; }
monitor_daemon() { :; }
sleep() { :; }
wg() {
	local polls
	case "$3" in
	allowed-ips) printf 'peer\t0.0.0.0/0 ::/0\n' ;;
	endpoints) printf 'peer\t203.0.113.7:51820\n' ;;
	listen-port)
		polls=$(( $(cat "$TEST_POLLS") + 1 ))
		echo "$polls" > "$TEST_POLLS"
		# wireguard-go binds its socket shortly after the interface comes up.
		if [[ $polls -ge 3 ]]; then echo 54321; else echo 0; fi ;;
	esac
}
netstat() {
	printf 'Routing tables\n\nInternet:\nDestination        Gateway            Flags               Netif Expire\n'
	[[ $3 == inet ]] || return 0
	printf 'default            %s          UGScg                 en0\n' "$TEST_GATEWAY"
	[[ -z $TEST_HOST_ROUTE ]] || printf '%s\n' "$TEST_HOST_ROUTE"
}
route() { printf 'route %s\n' "$*" >> "$TEST_EVENTS"; }
pfctl() {
	printf 'pfctl %s\n' "$*" >> "$TEST_EVENTS"
	[[ " $* " != *" -f - "* ]] || sed 's/^/rule /' >> "$TEST_EVENTS"
	# Enabling an already enabled packet filter fails; startup must tolerate it.
	[[ " $* " != *" -e "* ]]
}
'''


def build(root, guarded):
    script = root / 'wg-quick'
    script.write_text(load_source())
    for patch in PATCHES + (['wg-quick-loop-guard.patch'] if guarded else []):
        subprocess.run(['/usr/bin/patch', '--quiet', str(script), str(ROOT / 'Scripts' / patch)], check=True)
    return script.read_text()


def run(root, source, body, config='', host_route='', gateway='192.0.2.1'):
    events = root / 'events'
    polls = root / 'polls'
    events.write_text('')
    polls.write_text('0')
    fixture = root / 'fixture-script'
    fixture.write_text(source.replace('# ~~ function override insertion point ~~', FAKES + body))
    conf = root / 'fixture.conf'
    conf.write_text('[Interface]\nPrivateKey = synthetic\nAddress = 192.0.2.10/32\n' + config +
                    '[Peer]\nPublicKey = synthetic\nEndpoint = 203.0.113.7:51820\nAllowedIPs = 0.0.0.0/0, ::/0\n')
    conf.chmod(0o600)
    result = subprocess.run(['/bin/bash', str(fixture), 'up', str(conf)], capture_output=True, text=True,
                            env={'TEST_EVENTS': str(events), 'TEST_POLLS': str(polls),
                                 'TEST_GATEWAY': gateway, 'TEST_HOST_ROUTE': host_route})
    assert result.returncode == 0, result.stderr
    return events.read_text().splitlines()


def check(guarded=True):
    with tempfile.TemporaryDirectory(prefix='wiretunnels-loop-guard-test-') as directory:
        root = Path(directory)
        source = build(root, guarded)

        events = run(root, source, '')
        rule = 'rule block drop out quick on utun99 proto udp from any port 54321'
        endpoint = 'route -q -n add -inet 203.0.113.7 -gateway 192.0.2.1'
        catch_all = 'route -q -n add -inet 0.0.0.0/1 -interface utun99'
        assert rule in events, 'Startup did not drop wireguard-go packets that re-enter the tunnel: %r' % events
        assert 'pfctl -q -a com.apple/wiretunnels.guard.utun99 -f -' in events, events
        assert any(event.startswith('pfctl') and ' -e ' in event + ' ' for event in events), 'Guard loaded without enabling pf'
        assert events.index('up') < events.index(rule) < events.index(catch_all), 'Guard was not in place before routing'
        assert events.index(endpoint) < events.index(catch_all), 'Catch-all routes were added before the endpoint route'
        assert events.count(endpoint) == 1, 'Endpoint route was added more than once: %r' % events

        events = run(root, source, '', config='Table = off\n')
        assert not any(event.startswith(('pfctl', 'route')) for event in events), 'Table = off still touched routing: %r' % events

        # The default gateway moved; the endpoint route must be switched in place, never removed first.
        stale = '203.0.113.7        192.0.2.1          UGHS                  en0'
        moved = r'''
cmd_up() { :; }
REAL_INTERFACE=utun99
AUTO_ROUTE4=1
ENDPOINTS=( 203.0.113.7 )
GATEWAY4=192.0.2.1
set_endpoint_direct_route
'''
        events = run(root, source, moved, host_route=stale, gateway='192.0.2.254')
        assert events == ['route -q -n change -inet 203.0.113.7 -gateway 192.0.2.254'], events

        # A first lookup with no previous gateway still replaces a leftover route without a gap.
        first = moved.replace('GATEWAY4=192.0.2.1', 'GATEWAY4=').replace('ENDPOINTS=( 203.0.113.7 )', 'ENDPOINTS=( )')
        events = run(root, source, first, host_route=stale)
        assert events == ['route -q -n change -inet 203.0.113.7 -gateway 192.0.2.1'], events

        # Learned host routes (ARP entries for an endpoint on the local subnet) keep upstream's delete and add.
        arp = '203.0.113.7        0:11:22:33:44:55   UHLWIi                en0   1200'
        events = run(root, source, first, host_route=arp)
        assert events == ['route -q -n delete -inet 203.0.113.7', 'route -q -n add -inet 203.0.113.7 -gateway 192.0.2.1'], events

        teardown = r'''
cmd_up() { :; }
REAL_INTERFACE=utun99
del_routes
'''
        events = run(root, source, teardown)
        assert events == ['pfctl -q -a com.apple/wiretunnels.guard.utun99 -F all'], 'Teardown left the guard anchor behind: %r' % events
    print('PASS: wg-quick guards against routing loops before routing and moves endpoint routes without a gap')


if __name__ == '__main__':
    check('--baseline' not in sys.argv)
