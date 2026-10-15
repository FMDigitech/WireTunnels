import Foundation

@main
struct MenuBarSetupNoticeTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = WireGuardEnvironment()
        let missing = notice(environment)
        precondition(missing?.title == "WireGuard tools are not installed", "Missing tools must be explained in the menu")
        precondition(missing?.showsSettingsButton == true, "Missing tools must offer Settings")
        precondition(missing?.message.contains("Settings") == true)
        let starting = notice(environment, initialized: false)
        precondition(starting?.title == "Checking WireGuard setup", "Starting must not report an unconfirmed missing installation")
        precondition(starting?.showsSettingsButton == false)
        let approval = notice(environment, approval: true)
        precondition(approval?.title == "Privileged helper needs approval")
        for name in ["wg", "wg-quick", "wireguard-go"] {
            let path = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        environment.wgPath = directory.appendingPathComponent("wg").path
        environment.wgQuickPath = directory.appendingPathComponent("wg-quick").path
        environment.wireguardGoPath = directory.appendingPathComponent("wireguard-go").path
        environment.binariesInstalled = true
        environment.runtimeStatus = WireGuardRuntimeStatus(location: .installed, source: "Test fixture", generatedAt: nil,
            verifiedAt: Date(), artifacts: ["wg", "wg-quick", "wireguard-go"].map {
                WireGuardArtifactStatus(name: $0, version: "test", sourceURL: "https://example.invalid/tools",
                    revision: "fixture", architectures: ["arm64"], expectedSHA256: "fixture", actualSHA256: "fixture", isValid: true)
            }, errorMessage: nil)
        precondition(notice(environment)?.title == "Privileged helper is not installed")
        environment.helperInstalled = true
        precondition(notice(environment) == nil, "Ready installations must not show a setup warning")
        precondition(notice(environment, update: true)?.title == "WireGuard tools need an update")
        environment.wireguardGoPath = nil
        precondition(notice(environment)?.title == "WireGuard tools need reinstalling", "A damaged installation must explain disabled controls")
        print("PASS: menu explains missing tools, helper approval, updates, and incomplete setup without warning on ready installations")
    }

    private static func notice(_ environment: WireGuardEnvironment, initialized: Bool = true,
                               approval: Bool = false, update: Bool = false) -> MenuBarSetupNotice? {
        MenuBarSetupNotice(environment: environment, isInitialized: initialized,
                           helperRequiresApproval: approval, toolInstallRequired: update)
    }
}
