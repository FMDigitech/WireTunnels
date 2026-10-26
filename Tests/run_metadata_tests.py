#!/usr/bin/env python3
"""Compile and run the metadata persistence suite without an Xcode test target."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "Shared/InventoryRouting.swift",
    "WireTunnels/Models/AutoConnectRule.swift",
    "WireTunnels/Models/Tunnel.swift",
    "WireTunnels/Models/HopChain.swift",
    "WireTunnels/Services/AppPaths.swift",
    "WireTunnels/Services/RecoverableJSONStore.swift",
    "WireTunnels/Services/TunnelRepository.swift",
    "WireTunnels/Services/HopChainRepository.swift",
    "Tests/TunnelRepositoryTests.swift",
]


def main():
    with tempfile.TemporaryDirectory(prefix="wiretunnels-metadata-tests-") as temporary:
        directory = Path(temporary)
        executable = directory / "metadata-tests"
        subprocess.run([
            "swiftc", "-module-cache-path", str(directory / "module-cache"),
            *[str(ROOT / source) for source in SOURCES], "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
