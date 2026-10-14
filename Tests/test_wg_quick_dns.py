#!/usr/bin/env python3
"""Exercise DNS service selection against fake macOS network services."""
from pathlib import Path
import subprocess
import tempfile

from wg_quick_fixture import load_source

ROOT=Path(__file__).resolve().parent.parent
SOURCE=load_source()


def check(apply_active=True, active='Wi-Fi'):
    with tempfile.TemporaryDirectory(prefix='wiretunnels-dns-test-') as temporary:
        root=Path(temporary)
        script=root/'wg-quick'
        script.write_text(SOURCE)
        patches=['wg-quick-bash3.patch','wg-quick-cleanup.patch']+(['wg-quick-active-dns.patch'] if apply_active else [])
        for patch in patches:
            subprocess.run(['/usr/bin/patch','--quiet',str(script),str(ROOT/'Scripts'/patch)],check=True)
        # Use the real functions with fake networksetup/scutil; no system DNS changes.
        functions=script.read_text().split('# ~~ function override insertion point ~~')[0]
        fake=r'''
networksetup() {
 case "$1" in
  -listallnetworkservices) printf 'Service list\nWi-Fi\nEthernet\nUnused VPN\n' ;;
  -getdnsservers) printf 'read-dns:%s\n' "$2" >> "$TEST_EVENTS"; printf '192.0.2.53\n' ;;
  -getsearchdomains) printf 'read-search:%s\n' "$2" >> "$TEST_EVENTS"; printf 'original.example\n' ;;
  -setdnsservers) printf 'write-dns:%s:%s\n' "$2" "$3" >> "$TEST_EVENTS" ;;
  -setsearchdomains) printf 'write-search:%s:%s\n' "$2" "$3" >> "$TEST_EVENTS" ;;
 esac
}
scutil() {
 local query
 read -r query
 case "$query" in
  'show State:/Network/Global/IPv4'|'show State:/Network/Global/IPv6') printf '  PrimaryService : active-id\n' ;;
  'show Setup:/Network/Service/active-id') printf '  UserDefinedName : %s\n' "$TEST_ACTIVE" ;;
 esac
}
DNS=(192.0.2.99)
DNS_SEARCH=()
set_dns
printf 'first-finished\n' >> "$TEST_EVENTS"
TEST_ACTIVE=Ethernet
set_dns
printf 'second-finished\n' >> "$TEST_EVENTS"
del_dns
'''
        fixture=root/'fixture'
        fixture.write_text(functions+fake)
        events=root/'events'
        subprocess.run(['/bin/bash',str(fixture)],env={'TEST_EVENTS':str(events),'TEST_ACTIVE':active},capture_output=True,text=True,check=True)
        lines=events.read_text().splitlines()
        first=lines[:lines.index('first-finished')]
        if active != 'Wi-Fi':
            for service in ['Wi-Fi', 'Ethernet', 'Unused VPN']:
                assert f'read-dns:{service}' in first, 'Unavailable active-service lookup skipped DNS capture'
                assert f'write-dns:{service}:192.0.2.99' in first, 'Unavailable active-service lookup skipped DNS updates'
            return
        assert first==['read-dns:Wi-Fi','read-search:Wi-Fi','write-dns:Wi-Fi:192.0.2.99','write-search:Wi-Fi:Empty'], 'Cold startup rewrote inactive network services'
        second=lines[lines.index('first-finished')+1:lines.index('second-finished')]
        assert second==['read-dns:Ethernet','read-search:Ethernet','write-dns:Ethernet:192.0.2.99','write-search:Ethernet:Empty'], 'Network switch lost the new active service or rewrote inactive services'
        cleanup=lines[lines.index('second-finished')+1:]
        assert cleanup==['write-dns:Wi-Fi:192.0.2.53','write-search:Wi-Fi:original.example','write-dns:Ethernet:192.0.2.53','write-search:Ethernet:original.example'], 'Disconnect lost original DNS for a previously active service'
    print('PASS: DNS updates only active services and restores all touched services after switching networks')


if __name__=='__main__':
    import sys
    check('--baseline' not in sys.argv)
    if '--baseline' not in sys.argv:
        check(active='Missing Service')
        check(active='')
        print('PASS: absent and unavailable active-service names fall back to configured services')
