import Foundation
import SystemConfiguration

/// A local macOS account and whether it has a login session right now. Sharing a tunnel makes it
/// available to every account on this Mac, so this is the "who is using it" list: accounts on the
/// Mac, not remote WireGuard peers.
struct MacAccount: Identifiable, Equatable {
    enum SessionState: Equatable {
        case signedIn, background, signedOut

        var label: String {
            switch self {
            case .signedIn: return "Signed in"
            case .background: return "Signed in · background"
            case .signedOut: return "Signed out"
            }
        }

        var isSignedIn: Bool { self != .signedOut }
    }

    let name: String
    let uid: Int
    let isAdmin: Bool
    let isCurrentUser: Bool
    let state: SessionState

    var id: Int { uid }
    var roleLabel: String { isAdmin ? "Administrator" : "Standard user" }
}

enum MacAccountsService {
    /// Reads the local directory and the running login sessions. Blocking: call off the main actor.
    nonisolated static func load() -> [MacAccount] {
        let ids = run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])
            .split(separator: "\n")
            .compactMap { line -> (String, Int)? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count == 2, let uid = Int(parts[1]), uid >= 501, !parts[0].hasPrefix("_") else { return nil }
                return (String(parts[0]), uid)
            }
        let admins = Set(run("/usr/bin/dscl", [".", "-read", "/Groups/admin", "GroupMembership"])
            .split(whereSeparator: \.isWhitespace).dropFirst().map(String.init))
        // Every signed-in session runs its own loginwindow process owned by that account.
        let sessions = Set(run("/bin/ps", ["-axo", "user=,comm="])
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2, parts[1].hasSuffix("loginwindow") else { return nil }
                return String(parts[0])
            })
        let console = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?
        let me = NSUserName()
        return ids.map { name, uid in
            let state: MacAccount.SessionState = name == console ? .signedIn : (sessions.contains(name) ? .background : .signedOut)
            return MacAccount(name: name, uid: uid, isAdmin: admins.contains(name), isCurrentUser: name == me, state: state)
        }
        .sorted { ($0.isCurrentUser ? 0 : 1, $0.name) < ($1.isCurrentUser ? 0 : 1, $1.name) }
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
