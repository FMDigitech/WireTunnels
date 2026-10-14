#!/usr/bin/env python3
"""Compile and run disconnect regression suites without Xcode test targets."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run_suite(directory, name, sources, args=()):
    executable = directory / (name + '-tests')
    subprocess.run([
        'swiftc', '-module-cache-path', str(directory / 'module-cache'),
        *[str(ROOT / source) for source in sources], '-o', str(executable)
    ], check=True)
    subprocess.run([str(executable), *map(str, args)], check=True)


def main():
    with tempfile.TemporaryDirectory(prefix='wiretunnels-tests-') as temporary:
        directory = Path(temporary)
        status_model = 'WireTunnels/Models/TunnelStatus.swift'
        run_suite(directory, 'dns-recovery', ['WireTunnelsHelper/DNSRecoveryService.swift', 'Tests/DNSRecoveryTests.swift'])
        run_suite(directory, 'matching', [status_model, 'Tests/TunnelMatchingTests.swift'])
        run_suite(directory, 'commands', ['WireTunnelsHelper/CommandRunner.swift', 'Tests/CommandRunnerTests.swift'])
        run_suite(directory, 'logging', ['WireTunnels/Services/AppPaths.swift', 'WireTunnels/Services/LogService.swift', 'Tests/LogServiceTests.swift'])
        subprocess.run(['python3', str(ROOT / 'Tests/test_wg_quick_cleanup.py')], check=True)
        subprocess.run(['python3', str(ROOT / 'Tests/test_wg_quick_dns.py')], check=True)
        subprocess.run(['python3', str(ROOT / 'Tests/test_wg_quick_dns_recovery.py')], check=True)
        run_suite(directory, 'status', [status_model,
                  'WireTunnels/Services/StatusMonitorService.swift', 'Tests/StatusMonitorTests.swift'])
        run_suite(directory, 'duplication', [
            'WireTunnels/Models/AutoConnectRule.swift', 'WireTunnels/Models/Tunnel.swift',
            'WireTunnels/Services/AppPaths.swift', 'WireTunnels/Services/ConfigStorageService.swift',
            'WireTunnels/Services/WireGuardConfigParser.swift',
            'WireTunnels/Services/TunnelDuplicationService.swift', 'Tests/TunnelDuplicationTests.swift'
        ])
        run_suite(directory, 'shared-endpoint', [status_model,
            'WireTunnels/Services/WireGuardConfigParser.swift',
            'WireTunnels/Services/StatusMonitorService.swift', 'Tests/SharedEndpointLifecycleTests.swift'
        ])
        fixtures = directory / 'runtime'
        fixtures.mkdir()
        sockets = []
        try:
            for name, interface, mode in [
                ('full', 'utun7', 'valid'), ('stale', 'utun8', 'stale'),
                ('gone', 'utun9', 'gone'), ('unsafe', '../bad', 'unsafe'),
                ('regular', 'utun10', 'regular'), ('missing-config', 'utun11', 'missing'),
                ('linked', 'utun12', 'linked')
            ]:
                alias = fixtures / (name + '.name')
                alias.write_text(interface + '\n')
                if mode != 'missing':
                    (fixtures / (name + '.conf')).write_text('[Interface]\n')
                if mode in ('unsafe', 'gone'):
                    continue
                socket_path = fixtures / (interface + '.sock')
                if mode == 'regular':
                    socket_path.write_text('not a socket')
                    continue
                local_socket = socket.socket(socket.AF_UNIX)
                local_socket.bind(str(socket_path))
                sockets.append(local_socket)
                if mode == 'stale':
                    os.utime(alias, (1, 1))
                if mode == 'linked':
                    alias.unlink()
                    alias.symlink_to(fixtures / 'full.name')
            run_suite(directory, 'runtime', ['WireTunnelsHelper/RuntimeConfigLocator.swift',
                      'Tests/RuntimeConfigLocatorTests.swift'], [fixtures])
        finally:
            for local_socket in sockets:
                local_socket.close()


if __name__ == '__main__':
    main()
