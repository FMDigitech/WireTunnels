import Foundation

@main
struct MenuBarSetupNoticeTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = WireGuardEnvironment()
        let missingHelper = notice(environment)
        precondition(missingHelper?.title == "Privileged helper is not installed", "A missing helper must be explained first")
        precondition(missingHelper?.showsSettingsButton == true, "A missing helper must offer Settings")
        environment.helperInstalled = true
        let missing = notice(environment)
        precondition(missing?.title == "WireGuard tools are not ready", "Tools the helper hasn't verified must be explained in the menu")
        precondition(missing?.showsSettingsButton == true, "Unverified tools must offer Settings")
        precondition(missing?.message.contains("Settings") == true)
        environment.helperInstalled = false
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
        precondition(notice(environment)?.title == "Privileged helper is not installed")
        environment.helperInstalled = true
        precondition(notice(environment) == nil, "Ready installations must not show a setup warning")
        environment.wireguardGoPath = nil
        precondition(notice(environment)?.title == "WireGuard tools are incomplete", "A damaged installation must explain disabled controls")
        print("PASS: menu explains a missing helper, unverified tools, helper approval, and incomplete setup without warning on ready installations")
    }

    private static func notice(_ environment: WireGuardEnvironment, initialized: Bool = true,
                               approval: Bool = false) -> MenuBarSetupNotice? {
        MenuBarSetupNotice(environment: environment, isInitialized: initialized,
                           helperRequiresApproval: approval)
    }
}
