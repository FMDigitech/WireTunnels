#!/usr/bin/env python3
"""Compile and run the link quality tests without an Xcode test target."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "WireTunnels/Models/LinkQuality.swift",
    "Tests/LinkQualityTests.swift",
]

with tempfile.TemporaryDirectory(prefix="wiretunnels-linkquality-") as directory:
    output = Path(directory) / "link-quality-tests"
    subprocess.run(["swiftc", *[str(ROOT / source) for source in SOURCES],
                    "-module-cache-path", str(Path(directory) / "module-cache"),
                    "-o", str(output)], check=True, cwd=ROOT)
    subprocess.run([str(output)], check=True, cwd=ROOT)
