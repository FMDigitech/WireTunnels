#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="$ROOT_DIR/Scripts/wireguard-versions.env"
BUILD_SCRIPT="$ROOT_DIR/Scripts/build_wireguard_binaries.sh"
APP_PROTOCOL="$ROOT_DIR/WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift"
HELPER_PROTOCOL="$ROOT_DIR/WireTunnelsHelper/WireguardHelperProtocol.swift"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"
TOOL_INSTALLER="$ROOT_DIR/WireTunnelsHelper/ToolInstaller.swift"
ANCHOR_SCRIPT="$ROOT_DIR/Scripts/generate_tool_anchors.sh"
PROJECT="$ROOT_DIR/WireTunnels.xcodeproj/project.pbxproj"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
SETTINGS="$ROOT_DIR/WireTunnels/Views/Settings/SettingsView.swift"
COMMAND_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"
PATHS="$ROOT_DIR/WireTunnels/Services/AppPaths.swift"
MANIFEST_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardManifest.swift"
RUNTIME_STATUS="$ROOT_DIR/WireTunnels/Models/WireGuardRuntimeStatus.swift"

fail() {
    echo "secure runtime test failed: $*" >&2
    exit 1
}

[ -f "$VERSIONS" ] || fail "missing pinned WireGuard revisions"

grep -Eq '^WIREGUARD_GO_REVISION=[0-9a-f]{40}$' "$VERSIONS" ||
    fail "wireguard-go revision must be a full commit hash"
grep -Eq '^WIREGUARD_TOOLS_REVISION=[0-9a-f]{40}$' "$VERSIONS" ||
    fail "wireguard-tools revision must be a full commit hash"
grep -q 'https://git.zx2c4.com/wireguard-go' "$VERSIONS" ||
    fail "wireguard-go source must be official"
grep -q 'https://git.zx2c4.com/wireguard-tools' "$VERSIONS" ||
    fail "wireguard-tools source must be official"

! grep -Eq 'git .* pull' "$BUILD_SCRIPT" ||
    fail "build must not update from a moving branch"
grep -q 'manifest.json' "$BUILD_SCRIPT" ||
    fail "build must generate a runtime manifest"
grep -q 'shasum -a 256' "$BUILD_SCRIPT" ||
    fail "build must hash bundled artifacts"

[ -f "$MANIFEST_SERVICE" ] || fail "missing app-side manifest verifier"
[ -f "$RUNTIME_STATUS" ] || fail "missing runtime status model"
grep -q 'schemaVersion == 1' "$MANIFEST_SERVICE" ||
    fail "manifest verifier must reject unsupported schemas"
grep -q 'expectedArtifactNames' "$MANIFEST_SERVICE" ||
    fail "manifest verifier must enforce the exact artifact set"
grep -q 'runtimeConfigDir' "$PATHS" ||
    fail "paths must define the privileged runtime directory"
grep -q 'legacyRuntimeConfigDir' "$PATHS" ||
    fail "paths must preserve legacy runtime directories"
grep -q 'userMetadataDir' "$PATHS" ||
    fail "paths must define user metadata storage"
grep -q 'userLogsDir' "$PATHS" ||
    fail "paths must define user log storage"

for protocol in "$APP_PROTOCOL" "$HELPER_PROTOCOL"; do
    grep -q 'func toolStatus(reply' "$protocol" ||
        fail "protocol must expose toolStatus"
    ! grep -q 'installBundledTools' "$protocol" ||
        fail "protocol must not let clients trigger tool installation from their bundle"
    grep -q 'stageConfig(named' "$protocol" ||
        fail "protocol must stage configs by name"
    grep -q 'startTunnel(named' "$protocol" ||
        fail "protocol must start tunnels by name"
    grep -q 'stopTunnel(named' "$protocol" ||
        fail "protocol must stop tunnels by name"
    ! grep -Eq 'appBundlePath|sourcePath|destPath' "$protocol" ||
        fail "protocol must not accept arbitrary paths"
done

grep -q 'SecCodeCheckValidity' "$HELPER" ||
    fail "helper must validate the XPC client signature"
grep -q 'SecStaticCodeCheckValidity' "$HELPER" ||
    fail "helper must validate the complete signed app bundle"
grep -q 'runtimeConfigDir' "$HELPER" ||
    fail "helper must use the new runtime directory"
grep -q 'legacyRuntimeConfigDirs' "$HELPER" ||
    fail "helper must preserve legacy stop compatibility"
! grep -q 'clientBundleURL' "$HELPER" ||
    fail "helper must not install tools from the client's bundle"
grep -q 'source: { try ToolInstaller.bundledToolsDirectory() }' "$HELPER" ||
    fail "helper must install tools from its own bundle"
grep -q 'codeSignature(requirement: toolRequirement("wg"))' "$HELPER" &&
    grep -q 'codeSignature(requirement: toolRequirement("wireguard-go"))' "$HELPER" ||
    fail "helper must check wg and wireguard-go by code signature"
grep -q 'certificate leaf\[subject.OU\] = \\"\\(applicationTeamIdentifier)\\"' "$HELPER" ||
    fail "tool signatures must be pinned to the app's team"
grep -q 'sha256(ToolAnchors.wgQuickSHA256)' "$HELPER" ||
    fail "helper must check wg-quick against its compiled-in hash"
grep -q 'toolInstaller.ensureInstalled(name == "wg-quick" ? nil : \[name\])' "$HELPER" ||
    fail "helper must verify the tools a command runs right before launching it (all three for wg-quick)"
! grep -q 'isExecutableFile(atPath: wg.path)' "$HELPER" ||
    fail "helper must verify wg instead of only checking that it exists"
grep -q 'requireRegularFile(destination' "$TOOL_INSTALLER" ||
    fail "staged tools must be rejected unless they are regular files"
grep -q 'kSecCSStrictValidate' "$TOOL_INSTALLER" ||
    fail "tool signatures must be validated strictly"
grep -q 'requireProtected(directory' "$TOOL_INSTALLER" ||
    fail "installed tool directories must be root-owned and not writable by others"
[ -f "$ANCHOR_SCRIPT" ] || fail "missing tool anchor generator"
grep -q -- '--prepare-wg-quick' "$ANCHOR_SCRIPT" ||
    fail "anchor generator must reuse the build script's wg-quick patch chain"
grep -q 'generate_tool_anchors.sh' "$PROJECT" ||
    fail "helper target must generate its tool anchors before compiling"
grep -q 'Bundled wg-quick does not match the hash compiled into the helper' "$BUILD_SCRIPT" ||
    fail "app build must check the bundled wg-quick against the helper's hash"
grep -q -- '--identifier "$(basename "$path")"' "$BUILD_SCRIPT" ||
    fail "tools must be signed with the identifier the helper requires"

initialize_body="$(
    awk '
        /func initialize\(\) async/ { in_initialize = 1 }
        in_initialize { print }
        in_initialize && /^    }$/ { exit }
    ' "$MANAGER"
)"
! grep -q 'installBundledTools' "$MANAGER" ||
    fail "app must not ask the helper to install tools from the app bundle"
grep -q 'commandService.toolStatus()' "$MANAGER" ||
    fail "manager must gate setup on the helper's tool status"
grep -q 'refreshToolStatus()' <<<"$initialize_body" ||
    fail "initialization must wait for the helper's tool status"
grep -q 'expectedHelperVersion' "$COMMAND_SERVICE" ||
    fail "command service must publish the bundled helper version"
grep -q 'version != WireGuardCommandService.expectedHelperVersion' "$MANAGER" ||
    fail "initialization must replace a reachable but stale helper"
! grep -Eq 'Install Tools|Reinstall Tools' "$SETTINGS" ||
    fail "settings must not offer a manual tool installation"
grep -qi 'no download' "$SETTINGS" ||
    fail "settings must explain that installation performs no download"

echo "Secure runtime requirements are implemented"
