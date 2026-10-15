#!/usr/bin/env python3
"""Compile and run tunnel display-name regression suites."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory(prefix='wiretunnels-name-tests-') as temporary:
        directory = Path(temporary)
        storage_sources = ['WireTunnels/Services/AppPaths.swift',
                           'WireTunnels/Services/ConfigStorageService.swift']
        suites = [
            ('config-storage', storage_sources + ['Tests/ConfigStorageTests.swift']),
            ('config-name', storage_sources + ['WireTunnelsHelper/ConfigName.swift',
                                               'Tests/ConfigNameTests.swift']),
        ]
        for name, sources in suites:
            executable = directory / name
            subprocess.run([
                'swiftc', '-module-cache-path', str(directory / 'module-cache'),
                *[str(ROOT / source) for source in sources], '-o', str(executable)
            ], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    main()
