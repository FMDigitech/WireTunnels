#!/usr/bin/env python3
"""Compile and run the menu setup notice tests without an Xcode test target."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "WireTunnels/Models/WireGuardRuntimeStatus.swift",
    "WireTunnels/Models/WireGuardEnvironment.swift",
    "WireTunnels/Models/MenuBarSetupNotice.swift",
    "Tests/MenuBarSetupNoticeTests.swift",
]

with tempfile.TemporaryDirectory(prefix="wiretunnels-menu-setup-") as directory:
    output = Path(directory) / "menu-setup-tests"
    subprocess.run(["swiftc", *[str(ROOT / source) for source in SOURCES],
                    "-module-cache-path", str(Path(directory) / "module-cache"),
                    "-o", str(output)], check=True, cwd=ROOT)
    subprocess.run([str(output)], check=True, cwd=ROOT)
