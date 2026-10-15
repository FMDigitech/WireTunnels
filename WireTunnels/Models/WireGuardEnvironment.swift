import Foundation

struct WireGuardEnvironment: Equatable {
    var wgPath: String?          // /Library/Application Support/WireTunnels/bin/wg
    var wgQuickPath: String?     // /Library/Application Support/WireTunnels/bin/wg-quick
    var wireguardGoPath: String? // /Library/Application Support/WireTunnels/bin/wireguard-go
    var helperInstalled: Bool
    var binariesInstalled: Bool
    var runtimeStatus: WireGuardRuntimeStatus?

    var isReady: Bool {
        guard helperInstalled, binariesInstalled,
              let wgPath, let wgQuickPath, let wireguardGoPath,
              let runtimeStatus, runtimeStatus.location == .installed, runtimeStatus.isValid else {
            return false
        }
        return [wgPath, wgQuickPath, wireguardGoPath].allSatisfy {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    init() {
        self.wgPath = nil
        self.wgQuickPath = nil
        self.wireguardGoPath = nil
        self.helperInstalled = false
        self.binariesInstalled = false
        self.runtimeStatus = nil
    }
}
