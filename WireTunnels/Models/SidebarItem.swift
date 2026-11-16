import Foundation

/// The screens of the dashboard sidebar. Plain Swift (no SwiftUI) so services such as
/// `DashboardNavigation` can name a screen and the test scripts can compile them.
enum SidebarItem: String, CaseIterable, Hashable {
    case all = "All Tunnels"
    case active = "Active"
    case shared = "Shared"
    case favorites = "Favorites"
    case multiHop = "Multi-Hop"
    case profiles = "Network Profiles"
    case doctor = "Network Doctor"
    case mesh = "Mesh VPNs"
    case devTools = "Developer Tools"
    case warnings = "Warnings"
    case settings = "Settings"
    case log = "Log"

    var systemImage: String {
        switch self {
        case .all:       return "list.bullet"
        case .active:    return "bolt.fill"
        case .shared:    return "person.2.fill"
        case .favorites: return "star.fill"
        case .multiHop:  return "arrow.triangle.branch"
        case .profiles:  return "wifi"
        case .doctor:    return "stethoscope"
        case .mesh:      return "point.3.connected.trianglepath.dotted"
        case .devTools:  return "terminal"
        case .warnings:  return "exclamationmark.triangle.fill"
        case .settings:  return "gear"
        case .log:       return "doc.text"
        }
    }

    var usesTunnelDetail: Bool {
        switch self {
        case .all, .active, .shared, .favorites:
            return true
        case .multiHop, .profiles, .doctor, .mesh, .devTools, .warnings, .settings, .log:
            return false
        }
    }
}
