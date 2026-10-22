#!/usr/bin/env python3
"""Run the On-Demand editor regression with real SwiftUI controls."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory(prefix='wiretunnels-on-demand-tests-') as temporary:
        directory = Path(temporary)
        executable = directory / 'on-demand-editor-tests'
        subprocess.run([
            'swiftc', '-module-cache-path', str(directory / 'module-cache'),
            str(ROOT / 'WireTunnels/Models/AutoConnectRule.swift'),
            str(ROOT / 'WireTunnels/Models/IPSubnet.swift'),
            str(ROOT / 'WireTunnels/Views/Dashboard/OnDemandMatchSection.swift'),
            str(ROOT / 'Tests/OnDemandEditorTests.swift'),
            '-o', str(executable)
        ], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    main()
