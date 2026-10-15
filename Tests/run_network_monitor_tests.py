#!/usr/bin/env python3
"""Exercise real physical-network monitoring with controlled link snapshots."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory(prefix='wiretunnels-network-tests-') as temporary:
    directory = Path(temporary)
    # Keep test diagnostics separate from the app's real user log.
    logger = directory / 'TestLogService.swift'
    logger.write_text('import Foundation\n@MainActor final class LogService {\n'
        '    static let shared = LogService()\n'
        '    init(logFile: URL? = nil) {}\n'
        '    func info(_ message: String) {}\n}\n')
    executable = directory / 'network-monitor-tests'
    subprocess.run([
        'swiftc', '-module-cache-path', str(directory / 'module-cache'),
        *[str(ROOT / source) for source in [
            'WireTunnels/Models/AutoConnectRule.swift', 'WireTunnels/Models/Tunnel.swift',
            'WireTunnels/Services/InterfaceAddressCollector.swift',
            'WireTunnels/Services/PhysicalNetworkSnapshot.swift',
            'WireTunnels/Services/NetworkMonitorService.swift',
            'Tests/PhysicalNetworkMonitorTests.swift']],
        str(logger), '-o', str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)
