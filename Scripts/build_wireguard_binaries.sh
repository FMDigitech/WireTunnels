#!/bin/bash
# Builds wg, wg-quick and wireguard-go from pinned upstream sources and bundles
# them, with manifest.json, into the app's Resources/wireguard directory.
# Run from the "Build Wireguard Binaries" Xcode build phase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=wireguard-versions.env
source "$SCRIPT_DIR/wireguard-versions.env"

ARCHS_OUT=(arm64 x86_64)
PATCH_FILE="$SCRIPT_DIR/wg-quick-bash3.patch"
CACHE_DIR="$SRCROOT/build/wireguard/tools-$WIREGUARD_TOOLS_VERSION-go-$WIREGUARD_GO_VERSION"
OUT_DIR="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/wireguard"

# System tools first (BSD stat/install/patch), Go from Homebrew or the official installer.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
command -v go >/dev/null || { echo "error: Go toolchain not found (brew install go)"; exit 1; }

fetch() { # url tag commit dest
    local url="$1" tag="$2" commit="$3" dest="$4"
    if [[ ! -d "$dest/.git" ]]; then
        rm -rf "$dest"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$dest"
    fi
    local actual
    actual="$(git -C "$dest" rev-parse HEAD)"
    if [[ "$actual" != "$commit" ]]; then
        echo "error: $url $tag resolved to $actual, expected $commit"
        exit 1
    fi
}

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

build() {
    mkdir -p "$CACHE_DIR"
    fetch "$WIREGUARD_TOOLS_URL" "$WIREGUARD_TOOLS_VERSION" "$WIREGUARD_TOOLS_COMMIT" "$CACHE_DIR/wireguard-tools"
    fetch "$WIREGUARD_GO_URL" "$WIREGUARD_GO_VERSION" "$WIREGUARD_GO_COMMIT" "$CACHE_DIR/wireguard-go"

    local arch_flags="" arch
    for arch in "${ARCHS_OUT[@]}"; do arch_flags+=" -arch $arch"; done

    echo "Building wg $WIREGUARD_TOOLS_VERSION"
    make -C "$CACHE_DIR/wireguard-tools/src" clean >/dev/null
    CC="$(xcrun -f clang)" CFLAGS="-O3$arch_flags" LDFLAGS="$arch_flags" \
        make -C "$CACHE_DIR/wireguard-tools/src" wg >/dev/null

    echo "Building wireguard-go $WIREGUARD_GO_VERSION"
    local slices=()
    for arch in "${ARCHS_OUT[@]}"; do
        local goarch="$arch"
        [[ "$arch" == x86_64 ]] && goarch=amd64
        (cd "$CACHE_DIR/wireguard-go" && CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" GOFLAGS=-mod=readonly \
            go build -trimpath -ldflags "-s -w" -o "$CACHE_DIR/wireguard-go-$arch" .)
        slices+=("$CACHE_DIR/wireguard-go-$arch")
    done
    lipo -create "${slices[@]}" -output "$CACHE_DIR/wireguard-go-universal"

    echo "Patching wg-quick for /bin/bash 3.2"
    cp "$CACHE_DIR/wireguard-tools/src/wg-quick/darwin.bash" "$CACHE_DIR/wg-quick"
    patch --quiet "$CACHE_DIR/wg-quick" "$PATCH_FILE"
    /bin/bash -n "$CACHE_DIR/wg-quick"

    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"
    install -m 0755 "$CACHE_DIR/wireguard-tools/src/wg" "$OUT_DIR/wg"
    install -m 0755 "$CACHE_DIR/wireguard-go-universal" "$OUT_DIR/wireguard-go"
    install -m 0755 "$CACHE_DIR/wg-quick" "$OUT_DIR/wg-quick"

    local identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    [[ -n "$identity" && "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]] || identity="-"
    local timestamp="--timestamp"
    if [[ "$identity" == "-" || "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == "Apple Development:"* || "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == "Mac Developer:"* ]]; then
        timestamp="--timestamp=none"
    fi
    codesign --force --options runtime "$timestamp" --sign "$identity" "$OUT_DIR/wg" "$OUT_DIR/wireguard-go"
}

write_manifest() {
    local archs
    archs="$(printf '"%s",' "${ARCHS_OUT[@]}")"
    archs="[${archs%,}]"
    artifact() { # name version url revision
        local file="$OUT_DIR/$1"
        printf '    {"name": "%s", "version": "%s", "sourceURL": "%s", "revision": "%s", "architectures": %s, "sha256": "%s", "size": %s}' \
            "$1" "$2" "$3" "$4" "$archs" "$(sha256 "$file")" "$(wc -c < "$file" | tr -d ' ')"
    }
    {
        echo '{'
        echo '  "schemaVersion": 1,'
        echo "  \"generatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo '  "source": "Built from upstream git.zx2c4.com sources",'
        echo "  \"patches\": [{\"name\": \"wg-quick-bash3.patch\", \"sha256\": \"$(sha256 "$PATCH_FILE")\"}],"
        echo '  "artifacts": ['
        artifact wg "$WIREGUARD_TOOLS_VERSION" "$WIREGUARD_TOOLS_URL" "$WIREGUARD_TOOLS_COMMIT"; echo ','
        artifact wg-quick "$WIREGUARD_TOOLS_VERSION" "$WIREGUARD_TOOLS_URL" "$WIREGUARD_TOOLS_COMMIT"; echo ','
        artifact wireguard-go "$WIREGUARD_GO_VERSION" "$WIREGUARD_GO_URL" "$WIREGUARD_GO_COMMIT"; echo
        echo '  ]'
        echo '}'
    } > "$OUT_DIR/manifest.json"
}

build
write_manifest
echo "Bundled WireGuard tools in $OUT_DIR"
