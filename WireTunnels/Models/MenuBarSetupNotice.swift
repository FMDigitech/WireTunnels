import Foundation

struct MenuBarSetupNotice {
    let title: String
    let message: String
    let showsSettingsButton: Bool

    init?(environment: WireGuardEnvironment, isInitialized: Bool,
          helperRequiresApproval: Bool) {
        if !isInitialized {
            title = "Checking WireGuard setup"
            message = "Connections will be available once setup has been checked."
            showsSettingsButton = false
            return
        }
        showsSettingsButton = true
        if helperRequiresApproval {
            title = "Privileged helper needs approval"
            message = "Open Settings to enable the helper before connecting."
        } else if !environment.helperInstalled {
            title = "Privileged helper is not installed"
            message = "Complete the helper setup in Settings before connecting."
        } else if !environment.binariesInstalled {
            title = "WireGuard tools are not ready"
            message = "The helper installs them automatically. Open Settings to see why they failed, or Re-detect to retry."
        } else if !environment.isReady {
            title = "WireGuard tools are incomplete"
            message = "Run Re-detect in Settings so the helper can reinstall them."
        } else {
            return nil
        }
    }
}
