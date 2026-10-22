#!/usr/bin/env python3
"""Compile and run disconnect regression suites without Xcode test targets."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run_suite(directory, name, sources, args=(), flags=()):
    executable = directory / (name + '-tests')
    subprocess.run([
        'swiftc', '-module-cache-path', str(directory / 'module-cache'), *flags,
        *[str(ROOT / source) for source in sources], '-o', str(executable)
    ], check=True)
    subprocess.run([str(executable), *map(str, args)], check=True)


def main():
    with tempfile.TemporaryDirectory(prefix='wiretunnels-tests-') as temporary:
        directory = Path(temporary)
        status_model = 'WireTunnels/Models/TunnelStatus.swift'
        run_suite(directory, 'dns-recovery', ['WireTunnelsHelper/DNSRecoveryService.swift', 'Tests/DNSRecoveryTests.swift'])
        run_suite(directory, 'wireguard-dns', ['WireTunnels/Services/WireGuardConfigParser.swift', 'Tests/WireGuardDNSTests.swift'])
        run_suite(directory, 'kill-switch-rules', ['Shared/KillSwitchEntry.swift', 'Tests/KillSwitchRulesTests.swift'])
        subprocess.run(['bash', str(ROOT / 'Tests/test_inventory_routing.sh')], check=True)
        subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', 'Tests', '-p', 'test_server_ips.py'],
                       cwd=ROOT, env={**os.environ, 'PYTHONPATH': str(ROOT)}, check=True)
        run_suite(directory, 'ethernet-subnets', ['WireTunnels/Models/AutoConnectRule.swift',
                  'WireTunnels/Models/IPSubnet.swift', 'WireTunnels/Services/AutoConnectNetworkMatcher.swift',
                  'Tests/EthernetSubnetTests.swift'])
        run_suite(directory, 'interface-addresses', ['WireTunnels/Services/InterfaceAddressCollector.swift',
                  'Tests/InterfaceAddressCollectorTests.swift'])
        helper = (ROOT / 'WireTunnelsHelper/HelperTool.swift').read_text()
        start = helper.index('private enum ManagedAutoConnectInterface:')
        end = helper.index('private struct SystemSettings:', start)
        managed_fixture = directory / 'ManagedOnDemandFixture.swift'
        managed_fixture.write_text('import Foundation\n' + helper[start:end] + '\n'
                                   + (ROOT / 'Tests/ManagedOnDemandPersistenceTests.swift').read_text())
        run_suite(directory, 'managed-on-demand', ['WireTunnels/Models/AutoConnectRule.swift', managed_fixture])
        run_suite(directory, 'shutdown', ['WireTunnels/Services/TunnelShutdownCoordinator.swift', 'Tests/TunnelShutdownTests.swift'])
        run_suite(directory, 'readiness', ['WireTunnels/Models/WireGuardRuntimeStatus.swift',
                  'WireTunnels/Models/WireGuardEnvironment.swift', 'WireTunnels/Models/TunnelConnectionReadiness.swift',
                  'Tests/TunnelConnectionReadinessTests.swift'])
        run_suite(directory, 'connection-feedback', ['WireTunnels/Models/TunnelConnectionFeedback.swift', 'Tests/TunnelConnectionFeedbackTests.swift'])
        run_suite(directory, 'awake-timeout', ['WireTunnels/Services/AwakeTimeout.swift', 'Tests/AwakeTimeoutTests.swift'])
        run_suite(directory, 'menu-dismissal', ['WireTunnels/Services/MenuBarDismissalController.swift', 'Tests/MenuBarDismissalTests.swift'])
        run_suite(directory, 'matching', [status_model, 'Tests/TunnelMatchingTests.swift'])
        run_suite(directory, 'commands', ['WireTunnelsHelper/CommandRunner.swift', 'Tests/CommandRunnerTests.swift'])
        run_suite(directory, 'logging', ['WireTunnels/Services/AppPaths.swift', 'WireTunnels/Services/LogService.swift', 'Tests/LogServiceTests.swift'])
        subprocess.run(['python3', str(ROOT / 'Tests/test_wg_quick_cleanup.py')], check=True)
        subprocess.run(['python3', str(ROOT / 'Tests/test_wg_quick_dns.py')], check=True)
        subprocess.run(['python3', str(ROOT / 'Tests/test_wg_quick_dns_recovery.py')], check=True)
        run_suite(directory, 'status', [status_model,
                  'WireTunnels/Services/StatusMonitorService.swift', 'Tests/StatusMonitorTests.swift'])
        run_suite(directory, 'duplication', [
            'Shared/InventoryRouting.swift', 'WireTunnels/Models/AutoConnectRule.swift', 'WireTunnels/Models/Tunnel.swift',
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
