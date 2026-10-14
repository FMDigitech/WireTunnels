#!/usr/bin/env python3
"""Run patched DNS functions with synthetic helper and network operations."""
from pathlib import Path
import subprocess
import tempfile
import sys

from wg_quick_fixture import load_source

ROOT = Path(__file__).resolve().parent.parent
TOKEN = '11111111-1111-4111-8111-111111111111'


def check(apply_recovery=True):
    with tempfile.TemporaryDirectory(prefix='wiretunnels-dns-cli-test-') as temporary:
        root = Path(temporary)
        script = root / 'wg-quick'
        script.write_text(load_source())
        patches = ['wg-quick-bash3.patch', 'wg-quick-cleanup.patch', 'wg-quick-active-dns.patch']
        if apply_recovery:
            patches.append('wg-quick-dns-recovery.patch')
        for patch in patches:
            subprocess.run(['/usr/bin/patch', '--quiet', str(script), str(ROOT / 'Scripts' / patch)], check=True)
        functions = script.read_text().split('# ~~ function override insertion point ~~')[0]
        helper = root / 'helper'
        helper.write_text('''#!/bin/bash
printf '%s\\0' "$@" >> "$TEST_EVENTS"
printf '\\0' >> "$TEST_EVENTS"
exit "$TEST_HELPER_RESULT"
''')
        helper.chmod(0o755)
        fake = r'''
networksetup() {
    case "$1" in
    -listallnetworkservices) printf 'Service list\nWi-Fi\nEthernet\n' ;;
    -getdnsservers) printf '192.0.2.53\n' ;;
    -getsearchdomains) printf 'original.example\n' ;;
    -setdnsservers|-setsearchdomains) printf 'direct-write\n' >> "$TEST_DIRECT" ;;
    esac
}
scutil() {
    local query
    read -r query
    case "$query" in
    'show State:/Network/Global/IPv4'|'show State:/Network/Global/IPv6') printf 'PrimaryService : active-id\n' ;;
    'show Setup:/Network/Service/active-id') printf 'UserDefinedName : %s\n' "$TEST_ACTIVE" ;;
    esac
}
stat() { printf '1:99\n'; }
INTERFACE=fixture
REAL_INTERFACE=utun99
DNS=(192.0.2.10 2001:db8::10)
DNS_SEARCH=(corp.example other.example)
set_dns
TEST_ACTIVE=Ethernet
set_dns
del_dns
'''
        fixture = root / 'fixture'
        fixture.write_text(functions + fake)
        events = root / 'events'
        direct = root / 'direct'
        environment = {
            'WIRETUNNELS_DNS_HELPER': str(helper), 'WIRETUNNELS_DNS_TOKEN': TOKEN,
            'TEST_ACTIVE': 'Wi-Fi', 'TEST_EVENTS': str(events), 'TEST_DIRECT': str(direct),
            'TEST_HELPER_RESULT': '0',
        }
        result = subprocess.run(['/bin/bash', str(fixture)], env=environment, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert events.exists(), 'DNS functions bypassed the persistent recovery helper'
        calls = [call.split(b'\0') for call in events.read_bytes().split(b'\0\0') if call]
        def expected(service):
            return [part.encode() for part in ['--dns-set', TOKEN, 'fixture', 'utun99', '1:99', service,
                    '2', '192.0.2.10', '2001:db8::10', '2', 'corp.example', 'other.example']]
        assert calls == [expected('Wi-Fi'), expected('Ethernet'), [b'--dns-release', TOKEN.encode()]], calls
        assert not direct.exists(), 'Shell wrote DNS outside the journaled helper'
        events.unlink()
        environment['TEST_HELPER_RESULT'] = '7'
        result = subprocess.run(['/bin/bash', str(fixture)], env=environment, capture_output=True, text=True)
        assert result.returncode == 7, 'Shell DNS setup swallowed helper failure'
        print('PASS: Bash3 DNS functions delegate active services and propagate journal failures')


if __name__ == '__main__':
    check('--baseline' not in sys.argv)
