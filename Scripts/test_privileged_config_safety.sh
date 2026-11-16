#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"

grep -q 'validateConfigContents(contents)' "$HELPER" ||
    { echo "Helper must validate staged config contents independently" >&2; exit 1; }
runtime_validation_count="$(grep -c 'validateConfigContents(contents)' "$HELPER")"
[ "$runtime_validation_count" -ge 2 ] ||
    { echo "Helper must also revalidate existing runtime configs before execution" >&2; exit 1; }
grep -q '"preup", "postup", "predown", "postdown"' "$HELPER" ||
    { echo "Helper must reject every wg-quick shell hook" >&2; exit 1; }
RUNNER="$ROOT_DIR/WireTunnelsHelper/CommandRunner.swift"
# CommandRunner reads both pipes without blocking while the child runs, and enforces a deadline.
grep -q 'O_NONBLOCK' "$RUNNER" &&
grep -q 'while process.isRunning' "$RUNNER" &&
grep -q 'collect()' "$RUNNER" ||
    { echo "Helper must drain command pipes while the child process is running" >&2; exit 1; }
grep -q 'SIGKILL' "$RUNNER" ||
    { echo "Helper must be able to kill a command that exceeds its deadline" >&2; exit 1; }

echo "Privileged config and process safety checks passed"
