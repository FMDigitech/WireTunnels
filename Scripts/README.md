# Scripts

## build_wireguard_binaries.sh

An Xcode "Run Script" build phase that fetches, compiles, and bundles the WireGuard
binaries required by WireTunnels into the app bundle.

### What it does

1. **Checks prerequisites** — verifies that `go`, `git`, `make`, `lipo`, and `clang`
   are available, and prints a clear error with remediation steps if any are missing.

2. **Checks the build cache** — if all three binaries already exist in
   `build/wireguard-cache/` and the cached revisions and patch hashes match
   `Scripts/wireguard-versions.env`, compilation is skipped.

3. **Builds wireguard-go** (Apache 2.0) from
   `https://git.zx2c4.com/wireguard-go`:
   - Fetches and checks out the pinned commit in detached mode.
   - Compiles a native `arm64` slice (`GOOS=darwin GOARCH=arm64`).
   - Compiles a native `amd64` slice (`GOOS=darwin GOARCH=amd64`).
   - Combines them into a universal binary with `lipo`.

4. **Builds wg** (GPL-2.0) from
   `https://git.zx2c4.com/wireguard-tools`:
   - Fetches and checks out the pinned commit in detached mode.
   - Compiles an `arm64` slice using `clang -target arm64-apple-macos13`.
   - Compiles an `x86_64` slice using `clang -target x86_64-apple-macos13`.
   - Combines them into a universal binary with `lipo`.

5. **Prepares wg-quick** — applies `wg-quick-bash3.patch` to the upstream Darwin
   script and verifies it with macOS `/bin/bash` 3.2. The patch replaces Bash 4-only
   associative arrays and `BASHPID` usage while preserving the upstream behavior.

6. **Installs into the app bundle** — the three files (`wg`, `wg-quick`,
   `wireguard-go`) are copied to:
   ```
   $BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/wireguard/
   ```
   The privileged helper then installs them to
   `/Library/Application Support/WireTunnels/bin/` at runtime.

### Prerequisites

| Tool | Why needed | How to install |
|------|-----------|----------------|
| Go | Build wireguard-go | `brew install go` |
| git | Fetch pinned official source revisions | Xcode CLT (`xcode-select --install`) |
| make | Build wireguard-tools | Xcode CLT (`xcode-select --install`) |
| lipo | Create universal binaries | Xcode CLT (bundled) |
| clang | Cross-compile wg slices | Xcode CLT (bundled) |

### How to add it as an Xcode build phase

1. In Xcode, select the **WireTunnels** target.
2. Open the **Build Phases** tab.
3. Click **+** and choose **New Run Script Phase**.
4. Set the shell to `/bin/bash`.
5. Paste the following as the script body:
   ```bash
   "${SRCROOT}/Scripts/build_wireguard_binaries.sh"
   ```
6. Move the phase **before** the "Copy Bundle Resources" phase.
7. Optionally, add `${SRCROOT}/build/wireguard-cache/wireguard-go` etc. to the
   **Output Files** list so Xcode can skip the phase when the cache is fresh.

### Cache location

```
<project root>/build/wireguard-cache/
├── .built_version          # revisions, patch hashes and signing identity; used for cache invalidation
├── wireguard-go            # universal binary
├── wireguard-go-arm64      # intermediate slice
├── wireguard-go-amd64      # intermediate slice
├── wg                      # universal binary
├── wg-arm64                # intermediate slice
├── wg-amd64                # intermediate slice
├── wg-quick                # Darwin script patched for macOS Bash 3.2
├── wireguard-go-src/       # cloned wireguard-go repo
└── wireguard-tools-src/    # cloned wireguard-tools repo
```

The `build/` directory is excluded from version control via `.gitignore`.

### Forcing a rebuild

Delete the cache directory and build again:

```bash
rm -rf "$(git rev-parse --show-toplevel)/build/wireguard-cache"
```

Then trigger a build in Xcode (Cmd+B). The script checks out the immutable
revisions in `Scripts/wireguard-versions.env`, recompiles, and recreates the
universal artifacts.

### License notes

| Binary | Source | License |
|--------|--------|---------|
| `wireguard-go` | https://git.zx2c4.com/wireguard-go | Apache License 2.0 |
| `wg` | https://git.zx2c4.com/wireguard-tools | GNU GPL v2.0 |
| `wg-quick` | https://git.zx2c4.com/wireguard-tools | GNU GPL v2.0 |

The GPL-2.0 binaries (`wg`, `wg-quick`) are built from source and bundled inside the
app. Distributing them requires making the corresponding source code available to
recipients. The canonical source is the upstream repository listed above. Consult your
legal counsel if you plan to distribute WireTunnels outside of personal use.

### Security regression test

Run the secure runtime checks with:

```bash
/bin/bash Scripts/test_secure_runtime.sh
```

### Runtime provenance and release security

The app never downloads executable code at runtime. `wg`, `wg-quick`, and
`wireguard-go` are built from the official repositories at the full commit
hashes recorded in `Scripts/wireguard-versions.env`. The tracked macOS patches
are applied after checkout.

Every build writes `Resources/wireguard/manifest.json` with source URLs,
revisions, architectures, patch hashes, artifact sizes, and SHA256 values for
display in Settings. Nothing trusts it for installation.

The privileged helper installs the tools itself, only from its own app bundle,
at start and whenever they fail verification. It checks each staged copy
against anchors compiled into the helper: `wg` and `wireguard-go` must be
signed with the app's team and their own identifier, and `wg-quick` must match
the SHA-256 that `Scripts/generate_tool_anchors.sh` generates before the helper
compiles. The app's copy step fails the build if the bundled `wg-quick` doesn't
match that hash. Right before each run, the helper re-checks the tools that run.

Before distributing a release:

1. Archive with a Developer ID Application certificate and hardened runtime.
2. Verify the app and embedded helper with `codesign --verify --deep --strict`.
3. Submit the archive with `xcrun notarytool submit ... --wait`.
4. Staple with `xcrun stapler staple WireTunnels.app`.
5. Verify with `xcrun stapler validate WireTunnels.app` and
   `spctl --assess --type execute --verbose WireTunnels.app`.
6. Install the app in `/Applications` and test helper approval, automatic tool
   installation, connect, and disconnect on a clean account.
