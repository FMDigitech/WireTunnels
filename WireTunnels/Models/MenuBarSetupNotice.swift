import Foundation

struct MenuBarSetupNotice {
    let title: String
    let message: String
    let showsSettingsButton: Bool

    init?(environment: WireGuardEnvironment, isInitialized: Bool,
          helperRequiresApproval: Bool, toolInstallRequired: Bool) {
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
        } else if !environment.binariesInstalled {
            title = "WireGuard tools are not installed"
            message = "Install the tools in Settings before connecting to a tunnel."
        } else if !environment.helperInstalled {
            title = "Privileged helper is not installed"
            message = "Complete the helper setup in Settings before connecting."
        } else if toolInstallRequired {
            title = "WireGuard tools need an update"
            message = "Install the current bundled tools from Settings before connecting."
        } else if !environment.isReady {
            title = "WireGuard tools need reinstalling"
            message = "Reinstall and verify the tools in Settings before connecting."
        } else {
            return nil
        }
    }
}
