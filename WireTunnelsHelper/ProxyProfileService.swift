import Foundation
import SystemConfiguration

/// Sets and restores the proxy of the primary network service for a network profile.
///
/// Only the Proxies configuration of one service changes. Before the first change the settings it
/// replaces are written to a journal, so `release` (and a later run after a crash or restart)
/// puts back exactly what was there. While a profile stays active its journal keeps the original
/// settings: a second `apply` replaces the profile's proxy, never the user's own.
final class ProxyProfileService {
    enum ProxyError: LocalizedError {
        case noPrimaryService
        case preferences(String)
        case journal(String)

        var errorDescription: String? {
            switch self {
            case .noPrimaryService: return "There is no active network service to set a proxy on."
            case .preferences(let message): return "The network settings could not be changed: \(message)"
            case .journal(let message): return "The previous proxy settings could not be saved: \(message)"
            }
        }
    }

    static let shared = ProxyProfileService(
        journalURL: URL(fileURLWithPath: "/Library/Application Support/WireTunnels/proxy-state.json"))

    private let journalURL: URL
    private let lock = NSLock()

    init(journalURL: URL) {
        self.journalURL = journalURL
    }

    /// Applies `settings` to the primary service. Settings were validated by the caller.
    func apply(_ settings: ProxySettings) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let serviceID = Self.primaryServiceID() else { throw ProxyError.noPrimaryService }

        var journal = readJournal()
        // The default route moved to another service: give the old one its settings back first.
        if let existing = journal, existing.serviceID != serviceID {
            try restore(existing)
            try removeJournal()
            journal = nil
        }

        try withService(id: serviceID, createProxies: true) { prefs, proxies in
            let current = (SCNetworkProtocolGetConfiguration(proxies) as? [String: Any])
            if journal == nil {
                // Written before the change: a crash in between must still be recoverable.
                let created = try ProxyJournal(serviceID: serviceID, previous: current)
                try writeJournal(created)
                journal = created
            }
            let base = journal?.previousConfiguration ?? [:]
            guard SCNetworkProtocolSetConfiguration(proxies, settings.configuration(over: base) as CFDictionary) else {
                throw ProxyError.preferences(Self.lastError())
            }
            try commit(prefs)
        }
    }

    /// Restores what the profile replaced, if it replaced anything. Safe to call at any time.
    func release() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let journal = readJournal() else { return }
        try restore(journal)
        try removeJournal()
    }

    // MARK: System configuration

    private func restore(_ journal: ProxyJournal) throws {
        // A service that no longer exists has nothing to restore.
        try withService(id: journal.serviceID, createProxies: false) { prefs, proxies in
            let previous = journal.previousConfiguration
            guard SCNetworkProtocolSetConfiguration(proxies, previous.map { $0 as CFDictionary }) else {
                throw ProxyError.preferences(Self.lastError())
            }
            try commit(prefs)
        }
    }

    private func withService(id: String, createProxies: Bool,
                             _ body: (SCPreferences, SCNetworkProtocol) throws -> Void) throws {
        guard let prefs = SCPreferencesCreate(nil, "WireTunnels profile proxy" as CFString, nil) else {
            throw ProxyError.preferences(Self.lastError())
        }
        guard SCPreferencesLock(prefs, true) else { throw ProxyError.preferences(Self.lastError()) }
        defer { SCPreferencesUnlock(prefs) }
        guard let service = SCNetworkServiceCopy(prefs, id as CFString) else {
            if createProxies { throw ProxyError.noPrimaryService }
            return
        }
        var proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
        if proxies == nil, createProxies {
            guard SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeProxies) else {
                throw ProxyError.preferences(Self.lastError())
            }
            proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
        }
        guard let proxies else { return }
        try body(prefs, proxies)
    }

    private func commit(_ prefs: SCPreferences) throws {
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw ProxyError.preferences(Self.lastError())
        }
    }

    private static func lastError() -> String {
        String(cString: SCErrorString(SCError()))
    }

    /// The service that carries the default route, which is where a profile's proxy applies.
    static func primaryServiceID() -> String? {
        let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4)
        guard let store = SCDynamicStoreCreate(nil, "WireTunnels profile proxy" as CFString, nil, nil),
              let state = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return nil }
        return state[kSCDynamicStorePropNetPrimaryService as String] as? String
    }

    // MARK: Journal

    private func readJournal() -> ProxyJournal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? JSONDecoder().decode(ProxyJournal.self, from: data)
    }

    private func writeJournal(_ journal: ProxyJournal) throws {
        do {
            let directory = journalURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        } catch {
            throw ProxyError.journal(error.localizedDescription)
        }
    }

    private func removeJournal() throws {
        do {
            try FileManager.default.removeItem(at: journalURL)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            throw ProxyError.journal(error.localizedDescription)
        }
    }
}
