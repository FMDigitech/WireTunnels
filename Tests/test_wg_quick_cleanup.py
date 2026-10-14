#!/usr/bin/env python3
"""Exercise the actual bundled wg-quick startup trap with fake network operations."""
from pathlib import Path
import subprocess
import tempfile

from wg_quick_fixture import load_source

ROOT = Path(__file__).resolve().parent.parent
SOURCE = load_source()


def check(apply_cleanup=True):
    with tempfile.TemporaryDirectory(prefix='wiretunnels-quick-test-') as directory:
        root = Path(directory)
        script = root / 'wg-quick'
        script.write_text(SOURCE)
        patches = ['wg-quick-bash3.patch'] + (['wg-quick-cleanup.patch'] if apply_cleanup else [])
        for patch in patches:
            subprocess.run(['/usr/bin/patch', '--quiet', str(script), str(ROOT / 'Scripts' / patch)], check=True)
        config = root / 'fixture.conf'
        config.write_text('[Interface]\nPrivateKey = synthetic\nAddress = 192.0.2.1/32\nDNS = 192.0.2.53\n[Peer]\nPublicKey = synthetic\nAllowedIPs = 192.0.2.0/24\n')
        config.chmod(0o600)
        for fail in [True, False]:
            events = root / 'events'
            dns = root / 'dns'
            events.write_text('')
            dns.write_text('original')
            overrides = r'''
auto_su() { :; }
detect_launchd() { unset LAUNCHED_BY_LAUNCHD; }
get_real_interface() { return 1; }
add_if() { REAL_INTERFACE=utun99; }
set_config() { :; }
add_addr() { :; }
set_mtu() { :; }
up_if() { :; }
add_route() { :; }
wg() { printf 'peer 192.0.2.0/24\n'; }
set_dns() { printf changed > "$TEST_DNS"; return TEST_RESULT; }
del_dns() { printf restored > "$TEST_DNS"; printf 'dns-restored\n' >> "$TEST_EVENTS"; }
del_if() { printf 'interface-removed\n' >> "$TEST_EVENTS"; }
del_routes() { printf 'routes-removed\n' >> "$TEST_EVENTS"; }
monitor_daemon() { printf 'monitor-started\n' >> "$TEST_EVENTS"; }
'''.replace('TEST_RESULT', '7' if fail else '0')
            fixture = root / 'fixture-script'
            fixture.write_text(script.read_text().replace('# ~~ function override insertion point ~~', overrides))
            result = subprocess.run(['/bin/bash', str(fixture), 'up', str(config)], env={'TEST_DNS': str(dns), 'TEST_EVENTS': str(events)}, capture_output=True, text=True)
            if fail:
                assert dns.read_text() == 'restored', 'Failed startup left VPN DNS behind'
                assert events.read_text().splitlines() == ['dns-restored', 'interface-removed', 'routes-removed'], 'Failed startup did not restore DNS before discarding its interface'
                assert result.returncode == 7, 'Startup cleanup swallowed the original failure status'
            else:
                assert result.returncode == 0 and dns.read_text() == 'changed', 'Successful startup unexpectedly restored DNS'
                assert events.read_text().splitlines() == ['monitor-started'], 'Successful startup ran failure cleanup'
    print('PASS: wg-quick restores DNS after failed startup and preserves successful startup and error status')


if __name__ == '__main__':
    import sys
    check('--baseline' not in sys.argv)
