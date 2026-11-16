import Foundation

/// One proxy server: a host name or IP literal and a port.
nonisolated struct ProxyEndpoint: Codable, Equatable, Hashable {
    var host: String
    var port: Int
}

/// The proxy a network profile sets on the primary network service. Shared by the app and the
/// helper: the app checks it before sending, and the helper checks it again before it touches
/// system settings as root.
nonisolated struct ProxySettings: Codable, Equatable, Hashable {
    enum Mode: String, Codable, CaseIterable {
        /// Every proxy off on this network.
        case off
        /// The listed HTTP, HTTPS and SOCKS servers.
        case manual
        /// A proxy auto-configuration (PAC) file.
        case automatic

        var displayName: String {
            switch self {
            case .off: return "No proxy"
            case .manual: return "Manual"
            case .automatic: return "Automatic (PAC file)"
            }
        }
    }

    static let maxBypassEntries = 64

    var mode: Mode = .off
    var web: ProxyEndpoint?
    var secureWeb: ProxyEndpoint?
    var socks: ProxyEndpoint?
    var autoConfigURL: String?
    /// Hosts and networks that skip the proxy (`*.local`, `10.0.0.0/8`). Manual mode only.
    var bypass: [String] = []

    // MARK: Validation

    private static let hostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
    private static let bypassCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:*/")

    /// A name or IP literal without spaces, brackets or anything a settings file would read as syntax.
    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && !host.hasPrefix("-")
            && host.unicodeScalars.allSatisfy { hostCharacters.contains($0) }
    }

    static func isValidBypassEntry(_ entry: String) -> Bool {
        !entry.isEmpty && entry.count <= 253 && !entry.hasPrefix("-")
            && entry.unicodeScalars.allSatisfy { bypassCharacters.contains($0) }
    }

    static func isValidAutoConfigURL(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 2048,
              text.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static func problem(with endpoint: ProxyEndpoint, named name: String) -> String? {
        if !isValidHost(endpoint.host) { return "The \(name) proxy host is not valid." }
        if !(1...65535).contains(endpoint.port) { return "The \(name) proxy port must be between 1 and 65535." }
        return nil
    }

    /// Why these settings cannot be applied, or nil when they are well formed.
    var problem: String? {
        switch mode {
        case .off:
            return nil
        case .manual:
            let endpoints = [("HTTP", web), ("HTTPS", secureWeb), ("SOCKS", socks)]
            guard endpoints.contains(where: { $0.1 != nil }) else { return "Set at least one proxy server." }
            for (name, endpoint) in endpoints {
                if let endpoint, let message = Self.problem(with: endpoint, named: name) { return message }
            }
            if bypass.count > Self.maxBypassEntries { return "At most \(Self.maxBypassEntries) bypass entries." }
            if let bad = bypass.first(where: { !Self.isValidBypassEntry($0) }) { return "\"\(bad)\" is not a valid bypass entry." }
            return nil
        case .automatic:
            guard let autoConfigURL, Self.isValidAutoConfigURL(autoConfigURL) else {
                return "The PAC file needs an http or https address."
            }
            return nil
        }
    }

    // MARK: System configuration

    /// The Proxies configuration of a network service with these settings applied over `base`.
    /// Keys these settings do not own stay as `base` has them. Every on/off flag is written, so a
    /// proxy `base` had enabled cannot survive a profile that does not use it.
    func configuration(over base: [String: Any]) -> [String: Any] {
        var result = base
        func setEndpoint(_ endpoint: ProxyEndpoint?, enable: String, host: String, port: String) {
            if let endpoint, mode == .manual {
                result[enable] = 1
                result[host] = endpoint.host
                result[port] = endpoint.port
            } else {
                result[enable] = 0
            }
        }
        setEndpoint(web, enable: "HTTPEnable", host: "HTTPProxy", port: "HTTPPort")
        setEndpoint(secureWeb, enable: "HTTPSEnable", host: "HTTPSProxy", port: "HTTPSPort")
        setEndpoint(socks, enable: "SOCKSEnable", host: "SOCKSProxy", port: "SOCKSPort")
        if mode == .automatic, let autoConfigURL {
            result["ProxyAutoConfigEnable"] = 1
            result["ProxyAutoConfigURLString"] = autoConfigURL
        } else {
            result["ProxyAutoConfigEnable"] = 0
        }
        // Auto-discovery (WPAD) is another way to get a proxy; a profile that sets its own turns it off.
        if mode != .off || result["ProxyAutoDiscoveryEnable"] != nil {
            result["ProxyAutoDiscoveryEnable"] = 0
        }
        if mode == .manual { result["ExceptionsList"] = bypass }
        return result
    }
}

/// What the helper keeps on disk while a profile's proxy is applied, so the settings the profile
/// replaced come back when it ends, even after a crash or a restart.
nonisolated struct ProxyJournal: Codable, Equatable {
    var serviceID: String
    /// The service's Proxies configuration before the profile, as a property list. nil: it had none.
    var previous: Data?

    init(serviceID: String, previous: [String: Any]?) throws {
        self.serviceID = serviceID
        self.previous = try previous.map {
            try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        }
    }

    var previousConfiguration: [String: Any]? {
        guard let previous else { return nil }
        return (try? PropertyListSerialization.propertyList(from: previous, options: [], format: nil)) as? [String: Any]
    }
}
