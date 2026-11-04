#!/usr/bin/env bash
# build_wireguard_binaries.sh
# Xcode build phase script: builds and bundles wg, wg-quick, wireguard-go
# as universal binaries (arm64 + x86_64) into the app bundle Resources/wireguard/
#
# --prepare-wg-quick only produces the patched wg-quick in the cache. The helper
# target runs it through generate_tool_anchors.sh before compiling, so the hash
# compiled into the helper comes from the same patch chain as the bundled script.

set -euo pipefail

# Xcode Run Script phases don't source ~/.zprofile, so Homebrew's PATH export
# there (Apple Silicon: /opt/homebrew/bin) is invisible here even though it
# works fine in Terminal. Add common toolchain locations explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
echo_info()    { echo -e "${BLUE}[WG-BUILD]${NC} $*"; }
echo_success() { echo -e "${GREEN}[WG-BUILD]${NC} $*"; }
echo_warn()    { echo -e "${YELLOW}[WG-BUILD]${NC} $*"; }
echo_error()   { echo -e "${RED}[WG-BUILD] ERROR:${NC} $*" >&2; }

# ── Paths ────────────────────────────────────────────────────────────────────
SRCROOT="${SRCROOT:-.}"
OUTPUT_DIR="${BUILT_PRODUCTS_DIR:-}/${CONTENTS_FOLDER_PATH:-}/Resources/wireguard"
TOOL_ANCHOR="${BUILT_PRODUCTS_DIR:-}/ToolAnchors/wg-quick.sha256"
CACHE_DIR="${SRCROOT}/build/wireguard-cache"
WG_GO_DIR="${CACHE_DIR}/wireguard-go-src"
WG_TOOLS_DIR="${CACHE_DIR}/wireguard-tools-src"
VERSION_FILE="${CACHE_DIR}/.built_version"
WG_QUICK_PATCH="${SRCROOT}/Scripts/wg-quick-bash3.patch"
WG_QUICK_DNS_PATCH="${SRCROOT}/Scripts/wg-quick-dns-cleanup.patch"
# Applied in this order on top of the two patches above.
WG_QUICK_EXTRA_PATCHES=(
    "${SRCROOT}/Scripts/wg-quick-cleanup.patch"
    "${SRCROOT}/Scripts/wg-quick-active-dns.patch"
    "${SRCROOT}/Scripts/wg-quick-dns-recovery.patch"
)
VERSIONS_FILE="${SRCROOT}/Scripts/wireguard-versions.env"

if [ ! -f "$VERSIONS_FILE" ]; then
    echo "Missing pinned source revisions: $VERSIONS_FILE" >&2
    exit 1
fi

# shellcheck source=wireguard-versions.env
source "$VERSIONS_FILE"

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
    local missing=0

    if ! command -v go &>/dev/null; then
        echo_error "Go not found. Install with: brew install go"
        echo_error "Then re-build the project."
        missing=1
    else
        echo_info "Go: $(go version)"
    fi

    if ! command -v git &>/dev/null; then
        echo_error "git not found."
        missing=1
    fi

    if ! command -v lipo &>/dev/null; then
        echo_error "lipo not found (should be part of Xcode CLT)."
        missing=1
    fi

    if ! command -v make &>/dev/null; then
        echo_error "make not found. Install Xcode Command Line Tools: xcode-select --install"
        missing=1
    fi

    if [ $missing -ne 0 ]; then
        exit 1
    fi
}

# ── Cache check ───────────────────────────────────────────────────────────────
get_versions() {
    local bash3_hash dns_hash
    bash3_hash=$(shasum -a 256 "$WG_QUICK_PATCH" | awk '{print $1}')
    dns_hash=$(shasum -a 256 "$WG_QUICK_DNS_PATCH" | awk '{print $1}')
    # The signing scheme and identity are part of the key: the helper rejects tools
    # signed ad-hoc or by another team, so a cache from such a build must not be reused.
    echo "${WIREGUARD_GO_REVISION}:${WIREGUARD_TOOLS_REVISION}:${bash3_hash}:${dns_hash}:sign-identifier-v1:${EXPANDED_CODE_SIGN_IDENTITY:--}"
}

is_cache_valid() {
    # Check all output files exist in cache
    for f in wg "wg-quick" wireguard-go; do
        [ -f "${CACHE_DIR}/${f}" ] || return 1
    done
    # Check version matches
    [ -f "$VERSION_FILE" ] || return 1
    local current_version
    current_version=$(get_versions)
    [ "$(cat "$VERSION_FILE")" = "$current_version" ] || return 1
    return 0
}

checkout_revision() {
    local repo_url="$1"
    local revision="$2"
    local destination="$3"

    if [ ! -d "$destination/.git" ]; then
        echo_info "Cloning official source: $repo_url"
        git clone --no-checkout "$repo_url" "$destination"
    fi

    if ! git -C "$destination" cat-file -e "${revision}^{commit}" 2>/dev/null; then
        echo_info "Fetching pinned revision: $revision"
        git -C "$destination" fetch --no-tags origin "$revision"
    fi

    git -C "$destination" checkout --detach --force "$revision"
    git -C "$destination" clean -fdx

    local checked_out
    checked_out=$(git -C "$destination" rev-parse HEAD)
    [ "$checked_out" = "$revision" ] || {
        echo_error "Pinned revision mismatch for $repo_url"
        exit 1
    }
}

# Signs a cached Mach-O binary once, at build time, so its bytes (and thus its
# manifest sha256) stay stable across every later build that hits the cache.
# codesign isn't byte-for-byte deterministic across separate invocations even on
# identical input with the same identity — re-signing on every build (as this
# used to do from copy_to_bundle) made the bundled binaries' hashes drift from
# what's already installed on every single rebuild, forcing a spurious
# "Reinstall Tools" prompt even when the actual WireGuard revision hadn't changed.
# The identifier is set explicitly: the helper only installs a tool whose signature
# has exactly this identifier and the app's team (see toolRequirement in HelperTool.swift).
# Without it, codesign derives one from the linker signature, like "wg-55554944…".
sign_cached_binary() {
    local path="$1"
    if file "$path" | grep -q "Mach-O"; then
        echo_info "Signing $(basename "$path") with Hardened Runtime..."
        codesign --force --options runtime --identifier "$(basename "$path")" \
            --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$path"
    fi
}

# ── wireguard-go build ────────────────────────────────────────────────────────
build_wireguard_go() {
    echo_info "Building wireguard-go..."

    checkout_revision "$WIREGUARD_GO_REPO" "$WIREGUARD_GO_REVISION" "$WG_GO_DIR"

    cd "$WG_GO_DIR"

    echo_info "Building wireguard-go arm64..."
    GOOS=darwin GOARCH=arm64 go build -o "${CACHE_DIR}/wireguard-go-arm64" .

    echo_info "Building wireguard-go amd64..."
    GOOS=darwin GOARCH=amd64 go build -o "${CACHE_DIR}/wireguard-go-amd64" .

    echo_info "Creating wireguard-go universal binary..."
    lipo -create -output "${CACHE_DIR}/wireguard-go" \
        "${CACHE_DIR}/wireguard-go-arm64" \
        "${CACHE_DIR}/wireguard-go-amd64"

    chmod +x "${CACHE_DIR}/wireguard-go"
    sign_cached_binary "${CACHE_DIR}/wireguard-go"
    echo_success "wireguard-go built: $(lipo -info "${CACHE_DIR}/wireguard-go" 2>&1 | tail -1)"
}

# ── wireguard-tools (wg + wg-quick) build ────────────────────────────────────
build_wireguard_tools() {
    echo_info "Building wireguard-tools..."

    checkout_revision "$WIREGUARD_TOOLS_REPO" "$WIREGUARD_TOOLS_REVISION" "$WG_TOOLS_DIR"

    local SRC_DIR="${WG_TOOLS_DIR}/src"
    cd "$SRC_DIR"

    # Build for arm64 using clang target triple
    echo_info "Building wg arm64..."
    make clean
    CC="clang" \
    CFLAGS="-target arm64-apple-macos13 -O2" \
    LDFLAGS="-target arm64-apple-macos13" \
    make wg
    cp wg "${CACHE_DIR}/wg-arm64"

    # Build for x86_64 using clang target triple
    echo_info "Building wg amd64..."
    make clean
    CC="clang" \
    CFLAGS="-target x86_64-apple-macos13 -O2" \
    LDFLAGS="-target x86_64-apple-macos13" \
    make wg
    cp wg "${CACHE_DIR}/wg-amd64"

    echo_info "Creating wg universal binary..."
    lipo -create -output "${CACHE_DIR}/wg" \
        "${CACHE_DIR}/wg-arm64" \
        "${CACHE_DIR}/wg-amd64"

    chmod +x "${CACHE_DIR}/wg"
    sign_cached_binary "${CACHE_DIR}/wg"
    echo_success "wg built: $(lipo -info "${CACHE_DIR}/wg" 2>&1 | tail -1)"

}

ensure_wireguard_tools_source() {
    if [ "$(git -C "$WG_TOOLS_DIR" rev-parse HEAD 2>/dev/null)" != "$WIREGUARD_TOOLS_REVISION" ] ||
        [ ! -f "${WG_TOOLS_DIR}/src/wg-quick/darwin.bash" ]; then
        checkout_revision "$WIREGUARD_TOOLS_REPO" "$WIREGUARD_TOOLS_REVISION" "$WG_TOOLS_DIR"
    fi
}

prepare_wg_quick() {
    local WQ_SRC="${WG_TOOLS_DIR}/src/wg-quick/darwin.bash"

    if [ ! -f "$WQ_SRC" ]; then
        echo_error "wg-quick not found at $WQ_SRC"
        exit 1
    fi
    if [ ! -f "$WG_QUICK_PATCH" ]; then
        echo_error "wg-quick compatibility patch not found at $WG_QUICK_PATCH"
        exit 1
    fi
    if [ ! -f "$WG_QUICK_DNS_PATCH" ]; then
        echo_error "wg-quick DNS cleanup patch not found at $WG_QUICK_DNS_PATCH"
        exit 1
    fi

    echo_info "Applying macOS Bash 3 compatibility patch to wg-quick..."
    if ! patch --silent -o "${CACHE_DIR}/wg-quick" "$WQ_SRC" < "$WG_QUICK_PATCH"; then
        echo_error "The wg-quick Bash 3 compatibility patch no longer applies"
        exit 1
    fi
    echo_info "Applying DNS cleanup patch to wg-quick..."
    if ! patch --silent -o "${CACHE_DIR}/wg-quick.dns" "${CACHE_DIR}/wg-quick" < "$WG_QUICK_DNS_PATCH"; then
        echo_error "The wg-quick DNS cleanup patch no longer applies"
        exit 1
    fi
    mv "${CACHE_DIR}/wg-quick.dns" "${CACHE_DIR}/wg-quick"
    for extra_patch in "${WG_QUICK_EXTRA_PATCHES[@]}"; do
        if [ ! -f "$extra_patch" ]; then
            echo_error "wg-quick patch not found at $extra_patch"
            exit 1
        fi
        echo_info "Applying $(basename "$extra_patch") to wg-quick..."
        if ! patch --silent -o "${CACHE_DIR}/wg-quick.next" "${CACHE_DIR}/wg-quick" < "$extra_patch"; then
            echo_error "$(basename "$extra_patch") no longer applies to wg-quick"
            exit 1
        fi
        mv "${CACHE_DIR}/wg-quick.next" "${CACHE_DIR}/wg-quick"
    done
    /bin/bash -n "${CACHE_DIR}/wg-quick"
    chmod +x "${CACHE_DIR}/wg-quick"
    /bin/bash "${SRCROOT}/Scripts/test_wg_quick_validator_path.sh" "${CACHE_DIR}/wg-quick"
    echo_success "wg-quick prepared for macOS Bash 3"
}

write_manifest() {
    local manifest="${OUTPUT_DIR}/manifest.json"
    local bash3_hash dns_hash generated_at
    bash3_hash=$(shasum -a 256 "$WG_QUICK_PATCH" | awk '{print $1}')
    dns_hash=$(shasum -a 256 "$WG_QUICK_DNS_PATCH" | awk '{print $1}')
    generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    artifact_json() {
        local name="$1"
        local source_url="$2"
        local revision="$3"
        local version="$4"
        local path="${OUTPUT_DIR}/${name}"
        local sha size architectures
        sha=$(shasum -a 256 "$path" | awk '{print $1}')
        # GNU stat (Homebrew coreutils) reads -f as --file-system.
        size=$(/usr/bin/stat -f '%z' "$path")
        if file "$path" | grep -q 'Mach-O'; then
            architectures='["arm64","x86_64"]'
        else
            architectures='["script"]'
        fi
        printf '{"name":"%s","version":"%s","sourceURL":"%s","revision":"%s","architectures":%s,"sha256":"%s","size":%s}' \
            "$name" "$version" "$source_url" "$revision" "$architectures" "$sha" "$size"
    }

    {
        printf '{\n'
        printf '  "schemaVersion": 1,\n'
        printf '  "generatedAt": "%s",\n' "$generated_at"
        printf '  "source": "official WireGuard source + tracked local patches",\n'
        printf '  "patches": [\n'
        printf '    {"name":"wg-quick-bash3.patch","sha256":"%s"},\n' "$bash3_hash"
        printf '    {"name":"wg-quick-dns-cleanup.patch","sha256":"%s"}' "$dns_hash"
        for extra_patch in "${WG_QUICK_EXTRA_PATCHES[@]}"; do
            printf ',\n    {"name":"%s","sha256":"%s"}' "$(basename "$extra_patch")" "$(shasum -a 256 "$extra_patch" | awk '{print $1}')"
        done
        printf '\n  ],\n'
        printf '  "artifacts": [\n'
        printf '    %s,\n' "$(artifact_json wg "$WIREGUARD_TOOLS_REPO" "$WIREGUARD_TOOLS_REVISION" "wireguard-tools@${WIREGUARD_TOOLS_REVISION:0:12}")"
        printf '    %s,\n' "$(artifact_json wg-quick "$WIREGUARD_TOOLS_REPO" "$WIREGUARD_TOOLS_REVISION" "wireguard-tools@${WIREGUARD_TOOLS_REVISION:0:12}+macos-patches")"
        printf '    %s\n' "$(artifact_json wireguard-go "$WIREGUARD_GO_REPO" "$WIREGUARD_GO_REVISION" "wireguard-go@${WIREGUARD_GO_REVISION:0:12}")"
        printf '  ]\n'
        printf '}\n'
    } > "$manifest"

    echo_success "Manifest: $manifest"
}

# ── Copy to app bundle ────────────────────────────────────────────────────────
copy_to_bundle() {
    echo_info "Copying binaries to app bundle: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"

    for f in wg "wg-quick" wireguard-go; do
        cp "${CACHE_DIR}/${f}" "${OUTPUT_DIR}/${f}"
        chmod +x "${OUTPUT_DIR}/${f}"
    done

    # The helper only installs a wg-quick matching the hash compiled into it
    # (generate_tool_anchors.sh), so fail the build instead of users' installs.
    if [ ! -f "$TOOL_ANCHOR" ]; then
        echo_error "Missing $TOOL_ANCHOR; build the WireTunnelsHelper target first"
        exit 1
    fi
    if [ "$(shasum -a 256 "${OUTPUT_DIR}/wg-quick" | awk '{print $1}')" != "$(cat "$TOOL_ANCHOR")" ]; then
        echo_error "Bundled wg-quick does not match the hash compiled into the helper"
        exit 1
    fi

    # wg and wireguard-go are already signed in the cache (see sign_cached_binary,
    # called from build_wireguard_go/build_wireguard_tools) — signing here again
    # on every build, even a cache hit, is what made their bytes (and manifest
    # sha256) drift on every rebuild despite unchanged pinned revisions.

    echo_success "Binaries in bundle:"
    for f in wg "wg-quick" wireguard-go; do
        if file "${OUTPUT_DIR}/${f}" | grep -q "Mach-O"; then
            echo_success "  ${f}: $(lipo -info "${OUTPUT_DIR}/${f}" 2>&1 | grep -o 'arm64.*' || echo 'binary')"
        else
            echo_success "  ${f}: script"
        fi
    done

    write_manifest
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    if [ "${1:-}" = "--prepare-wg-quick" ]; then
        mkdir -p "$CACHE_DIR"
        ensure_wireguard_tools_source
        prepare_wg_quick
        return
    fi

    echo_info "=== WireTunnels Binary Build Phase ==="
    echo_info "Output: $OUTPUT_DIR"
    echo_info "Cache:  $CACHE_DIR"

    mkdir -p "$CACHE_DIR"

    check_prerequisites

    if is_cache_valid; then
        echo_success "Cache valid — skipping build"
    else
        echo_info "Cache miss — building from source..."
        build_wireguard_go
        build_wireguard_tools
        # Save version
        get_versions > "$VERSION_FILE"
        echo_success "Build complete"
    fi

    prepare_wg_quick
    copy_to_bundle
    echo_success "=== Done ==="
}

main "$@"
