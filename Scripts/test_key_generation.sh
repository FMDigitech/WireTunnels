#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PROTOCOL="$ROOT_DIR/WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift"
HELPER_PROTOCOL="$ROOT_DIR/WireTunnelsHelper/WireguardHelperProtocol.swift"
COMMAND_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"

fail() {
    echo "key generation test failed: $*" >&2
    exit 1
}

protocol_signature='func generateKeyPair(reply: @escaping (String?, String?, String?) -> Void)'
for protocol in "$APP_PROTOCOL" "$HELPER_PROTOCOL"; do
    grep -Fq "$protocol_signature" "$protocol" ||
        fail "$(basename "$protocol") must expose private key, public key, and error"
done

grep -Fq 'func generateKeyPair() async throws -> (privateKey: String, publicKey: String)' \
    "$COMMAND_SERVICE" ||
    fail "command service must expose async key-pair generation"
grep -Fq 'proxy.generateKeyPair' "$COMMAND_SERVICE" ||
    fail "command service must call the privileged helper"
grep -Fq 'CommandError.keyGenerationFailed' "$COMMAND_SERVICE" ||
    fail "command service must propagate key-generation errors"
grep -Fq 'keyGenerationTimeoutNanoseconds' "$COMMAND_SERVICE" ||
    fail "key generation must have a bounded timeout"
grep -Fq 'remoteObjectProxyWithErrorHandler' "$COMMAND_SERVICE" ||
    fail "key generation must resume when the XPC connection is interrupted"
grep -Fq 'expectedHelperVersion = "1.0"' "$COMMAND_SERVICE" ||
    fail "app must require the helper version that supports key generation"

grep -Fq 'func generateKeyPair(reply: @escaping (String?, String?, String?) -> Void)' "$HELPER" ||
    fail "helper must implement key-pair generation"
grep -Fq 'toolInstaller.ensureInstalled(' "$HELPER" ||
    fail "helper must verify the installed wg binary before execution"
grep -Fq 'arguments: ["genkey"]' "$HELPER" ||
    fail "helper must execute wg genkey"
grep -Fq 'arguments: ["pubkey"]' "$HELPER" ||
    fail "helper must execute wg pubkey"
grep -Fq 'standardInput: privateKey + "\n"' "$HELPER" ||
    fail "helper must send the trimmed private key plus a newline to wg pubkey"
grep -Fq 'trimmingCharacters(in: .whitespacesAndNewlines)' "$HELPER" ||
    fail "helper must trim generated keys"
grep -Fq 'guard !privateKey.isEmpty' "$HELPER" ||
    fail "helper must reject an empty private key"
grep -Fq 'guard !publicKey.isEmpty' "$HELPER" ||
    fail "helper must reject an empty public key"
grep -Fq 'standardInput: String?' "$HELPER" ||
    fail "command runner must support stdin"
grep -Fq 'process.standardInput = stdinPipe' "$HELPER" ||
    fail "command runner must connect stdin to the child process"
grep -Fq 'helperVersionNumber = "1.0"' "$HELPER" ||
    fail "helper version must advance for the new XPC protocol"

echo "Privileged key generation requirements are implemented"
