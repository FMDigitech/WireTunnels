#!/usr/bin/env python3
"""Run config editor loading tests without an Xcode test target."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='wiretunnels-config-loading-') as temporary:
    directory = Path(temporary)
    executable = directory / 'config-loading-tests'
    subprocess.run(['swiftc', '-module-cache-path', str(directory / 'module-cache'),
                    str(ROOT / 'WireTunnels/Services/TunnelConfigLoadingState.swift'),
                    str(ROOT / 'Tests/TunnelConfigLoadingTests.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
