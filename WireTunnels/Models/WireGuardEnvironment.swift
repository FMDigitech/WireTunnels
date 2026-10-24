import Foundation

struct WireGuardEnvironment: Equatable {
    var wgPath: String?          // /Library/Application Support/WireTunnels/bin/wg
    var wgQuickPath: String?     // /Library/Application Support/WireTunnels/bin/wg-quick
    var wireguardGoPath: String? // /Library/Application Support/WireTunnels/bin/wireguard-go
    var helperInstalled: Bool
    /// Reported by the helper, which verifies the installed tools against its own anchors.
    var binariesInstalled: Bool

    var isReady: Bool {
        guard helperInstalled, binariesInstalled,
              let wgPath, let wgQuickPath, let wireguardGoPath else {
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
    }
}
