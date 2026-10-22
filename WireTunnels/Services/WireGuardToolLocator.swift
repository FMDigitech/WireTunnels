import Foundation

final class WireGuardToolLocator {
    private let verifier = WireGuardManifestVerifier()

    func detect() -> WireGuardEnvironment {
        var env = WireGuardEnvironment()
        let fm = FileManager.default

        if fm.isExecutableFile(atPath: AppPaths.wgPath) {
            env.wgPath = AppPaths.wgPath
        }
        if fm.isExecutableFile(atPath: AppPaths.wgQuickPath) {
            env.wgQuickPath = AppPaths.wgQuickPath
        }
        if fm.isExecutableFile(atPath: AppPaths.wireguardGoPath) {
            env.wireguardGoPath = AppPaths.wireguardGoPath
        }

        env.runtimeStatus = verifier.inspect(
            directory: AppPaths.systemBinDir,
            manifestURL: AppPaths.installedManifest,
            location: .installed
        )
        env.binariesInstalled = env.wgPath != nil
            && env.wgQuickPath != nil
            && env.wireguardGoPath != nil
            && env.runtimeStatus?.isValid == true

        return env
    }

    func bundledBinariesMatchInstalled() -> Bool {
        guard let bundledDir = AppPaths.bundledBinariesDir,
              let bundledManifest = AppPaths.bundledManifest else {
            return true
        }

        let bundled = verifier.inspect(
            directory: bundledDir,
            manifestURL: bundledManifest,
            location: .bundled
        )
        // A broken bundle cannot be installed, so it must not demand a reinstall.
        guard bundled.isValid else { return true }

        let installed = verifier.inspect(
            directory: AppPaths.systemBinDir,
            manifestURL: AppPaths.installedManifest,
            location: .installed
        )
        // Signing the app re-signs the bundled tools, so builds signed by another
        // identity differ only in code signatures and need no reinstall.
        return verifier.runtimesMatch(
            bundled: bundled,
            bundledDirectory: bundledDir,
            installed: installed,
            installedDirectory: AppPaths.systemBinDir
        )
    }

    func inspectBundledRuntime() -> WireGuardRuntimeStatus? {
        guard let directory = AppPaths.bundledBinariesDir,
              let manifest = AppPaths.bundledManifest else {
            return nil
        }
        return verifier.inspect(directory: directory, manifestURL: manifest, location: .bundled)
    }
}
