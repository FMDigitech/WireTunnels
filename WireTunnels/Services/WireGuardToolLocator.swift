import Foundation

final class WireGuardToolLocator {
    private let verifier = WireGuardManifestVerifier()

    /// Finds the installed tools. Whether they verify is up to the helper (`toolStatus`),
    /// which installs them from its own bundle and checks them before every run.
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

        return env
    }

    func inspectBundledRuntime() -> WireGuardRuntimeStatus? {
        guard let directory = AppPaths.bundledBinariesDir,
              let manifest = AppPaths.bundledManifest else {
            return nil
        }
        return verifier.inspect(directory: directory, manifestURL: manifest)
    }
}
