#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"

grep -q 'isInstalledApplicationBundle' "$SERVICE" ||
    { echo "Helper replacement must validate the app installation location" >&2; exit 1; }
grep -q 'helperReplacementRequiresInstalledApp' "$SERVICE" ||
    { echo "Unsafe helper replacement needs an actionable error" >&2; exit 1; }

guard_line="$(grep -n 'guard isInstalledApplicationBundle' "$SERVICE" | head -1 | cut -d: -f1)"
unregister_line="$(grep -nE 'try\??  *await unregisterHelper' "$SERVICE" | head -1 | cut -d: -f1)"
test -n "$guard_line" -a -n "$unregister_line" -a "$guard_line" -lt "$unregister_line" ||
    { echo "The app location must be validated before unregistering the old helper" >&2; exit 1; }

echo "Helper replacement preserves the existing helper when registration is unsafe"
