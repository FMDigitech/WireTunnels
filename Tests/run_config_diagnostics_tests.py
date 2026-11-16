#!/usr/bin/env python3
"""Compile and run the config diagnostics tests without an Xcode test target."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "WireTunnels/Services/WireGuardConfigParser.swift",
    "WireTunnels/Models/ConfigDiagnostics.swift",
    "Tests/ConfigDiagnosticsTests.swift",
]

with tempfile.TemporaryDirectory(prefix="wiretunnels-configdiagnostics-") as directory:
    output = Path(directory) / "config-diagnostics-tests"
    subprocess.run(["swiftc", *[str(ROOT / source) for source in SOURCES],
                    "-module-cache-path", str(Path(directory) / "module-cache"),
                    "-o", str(output)], check=True, cwd=ROOT)
    subprocess.run([str(output)], check=True, cwd=ROOT)
