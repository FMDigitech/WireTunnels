import Foundation

struct TunnelConnectionReadiness {
    let environment: WireGuardEnvironment
    let isInitialized: Bool
    let isLoading: Bool
    let needsSetup: Bool
    let isShuttingDown: Bool

    var canConnect: Bool {
        unavailableReason == nil
    }

    var unavailableReason: String? {
        if isShuttingDown {
            return "WireTunnels is quitting."
        }
        if !isInitialized {
            return "WireTunnels is starting. Try again in a moment."
        }
        if isLoading {
            return "WireTunnels is updating. Try again in a moment."
        }
        if !environment.helperInstalled {
            return "Complete the privileged helper setup in Settings before connecting."
        }
        if needsSetup || !environment.isReady {
            return "Install the WireGuard tools in Settings before connecting."
        }
        return nil
    }
}
