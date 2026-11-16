import Foundation

// A line-by-line reading of a WireGuard config for the editor, the form and the import review.
// It only says what is wrong with the text; `WireGuardConfigParser` stays the authority that
// decides whether a config can be saved. Valid syntax is not a connection test.

nonisolated enum DiagnosticSeverity: Int, Comparable {
    case error, warning, info
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Which row of the import checklist a problem belongs to.
nonisolated enum DiagnosticCategory: Equatable { case syntax, safety, required, format, note }

nonisolated struct ConfigDiagnostic: Identifiable, Equatable {
    let severity: DiagnosticSeverity
    let line: Int
    let message: String
    var hint = ""
    var category: DiagnosticCategory = .format
    var id: String { "\(line)|\(severity.rawValue)|\(message)" }
}

nonisolated enum ConfigLineKind: Equatable { case blank, comment, section, keyValue, invalid }

nonisolated struct ConfigEntry: Equatable {
    let line: Int
    let key: String
    let value: String
}

nonisolated struct ConfigSection: Equatable {
    let name: String   // "Interface", "Peer", or as written
    let line: Int
    var entries: [String: ConfigEntry] = [:]   // by lower-cased key
    var isKnown: Bool { name == "Interface" || name == "Peer" }

    subscript(key: String) -> ConfigEntry? { entries[key] }
    func value(_ key: String) -> String { entries[key]?.value ?? "" }
}

nonisolated struct ConfigReading {
    var lines: [ConfigLineKind] = []
    var sections: [ConfigSection] = []
    var diagnostics: [ConfigDiagnostic] = []
    var hasComments: Bool { lines.contains(.comment) }

    var interfaces: [ConfigSection] { sections.filter { $0.name == "Interface" } }
    var peers: [ConfigSection] { sections.filter { $0.name == "Peer" } }
    var errors: [ConfigDiagnostic] { diagnostics.filter { $0.severity == .error } }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
    var hasMissingEndpoint: Bool { diagnostics.contains { $0.message == ConfigWarning.missingEndpoint.rawValue } }

    /// The worst problem on a line, for the gutter and the line tint. Notes are not marked.
    func severity(onLine line: Int) -> DiagnosticSeverity? {
        diagnostics.filter { $0.line == line && $0.severity != .info }.map(\.severity).min()
    }
}

nonisolated enum ConfigDiagnostics {
    static let secretKeys: Set<String> = ["privatekey", "presharedkey"]
    private static let interfaceKeys: Set<String> = [
        "privatekey", "address", "dns", "listenport", "mtu", "table", "preup", "postup", "predown", "postdown",
        "saveconfig", "fwmark"
    ]
    private static let peerKeys: Set<String> = ["publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive"]
    private static let hookNames = ["preup": "PreUp", "postup": "PostUp", "predown": "PreDown", "postdown": "PostDown"]

    // MARK: Value checks (also used by the form)

    static func isKey(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9+/]{43}=$", options: .regularExpression) != nil }

    static func isAddress(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }

    /// An address with an optional prefix, as wg-quick accepts for `Address` and `AllowedIPs`.
    static func isAddressOrCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard isAddress(parts[0]) else { return false }
        guard parts.count == 2 else { return true }
        guard let prefix = Int(parts[1]), parts[1].allSatisfy(\.isNumber) else { return false }
        return prefix <= (parts[0].contains(":") ? 128 : 32)
    }

    static func isEndpoint(_ value: String) -> Bool {
        guard value.range(of: #"^(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):\d{1,5}$"#, options: .regularExpression) != nil,
              let port = Int(value.split(separator: ":").last ?? ""), (1...65535).contains(port) else { return false }
        return !value.hasPrefix("-")
    }

    static func list(_ text: String) -> [String] {
        text.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    static func isPlaceholder(_ value: String) -> Bool { value.range(of: "<[^>]*>", options: .regularExpression) != nil }

    // MARK: Reading

    static func read(_ text: String) -> ConfigReading {
        var reading = ConfigReading()
        var current: Int?
        func add(_ severity: DiagnosticSeverity, _ line: Int, _ message: String, _ hint: String = "", _ category: DiagnosticCategory = .syntax) {
            reading.diagnostics.append(ConfigDiagnostic(severity: severity, line: line, message: message, hint: hint, category: category))
        }

        let rawLines = text.components(separatedBy: "\n")
        for (index, rawLine) in rawLines.enumerated() {
            let number = index + 1
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            switch ConfigSafety.firstViolation(in: line) {
            case .controlCharacter?:
                add(.error, number, ConfigValidationError.controlCharacters.message,
                    "Paste it as plain text and remove hidden characters.", .safety)
            case .hook(let key)?:
                add(.error, number, ConfigValidationError.unsupportedDirective(hookNames[key] ?? key).message,
                    "WireTunnels never runs scripts from a config. Remove this line.", .safety)
            case nil: break
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { reading.lines.append(.blank); continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { reading.lines.append(.comment); continue }

            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let written = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                let known = ["interface", "peer"].contains(written.lowercased())
                reading.sections.append(ConfigSection(name: known ? written.capitalized : written, line: number))
                current = reading.sections.count - 1
                reading.lines.append(.section)
                if !known { add(.error, number, "[\(written)] is not a WireGuard section.", "Use [Interface] or [Peer].") }
                continue
            }

            guard let equals = trimmed.firstIndex(of: "="),
                  case let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces),
                  key.range(of: "^[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) != nil else {
                reading.lines.append(.invalid)
                add(.error, number, "This line is not valid.", "Write settings as Key = Value.")
                continue
            }
            // wg-quick drops everything from "#", so a trailing comment is not part of the value.
            let value = String(trimmed[trimmed.index(after: equals)...].prefix { $0 != "#" })
                .trimmingCharacters(in: .whitespaces)
            let lower = key.lowercased()
            reading.lines.append(.keyValue)
            guard let section = current else {
                add(.error, number, "\(key) is outside any section.", "Put it under [Interface] or [Peer].")
                continue
            }
            if reading.sections[section].entries[lower] != nil {
                add(.warning, number, "\(key) appears twice in [\(reading.sections[section].name)].",
                    "Only one value is used. Remove the other.", .note)
            }
            reading.sections[section].entries[lower] = ConfigEntry(line: number, key: key, value: value)
            let isInterface = reading.sections[section].name == "Interface", isPeer = reading.sections[section].name == "Peer"
            if let known = isInterface ? AmneziaWGKeys.interfaceKind(of: key) : isPeer ? AmneziaWGKeys.peerKind(of: key) : nil {
                if !AmneziaWGKeys.isValid(value, kind: known.kind) {
                    add(.error, number, ConfigValidationError.invalidAmneziaValue(known.name).message, "", .format)
                }
            } else if isInterface && !interfaceKeys.contains(lower) {
                add(.warning, number, "\(key) is not a known [Interface] setting.", "Check the spelling.", .note)
            } else if isPeer && !peerKeys.contains(lower) {
                add(.warning, number, "\(key) is not a known [Peer] setting.", "Check the spelling.", .note)
            }
        }

        reading.diagnostics += sectionDiagnostics(of: reading, lineCount: rawLines.count)
        reading.diagnostics.sort { ($0.line, $0.severity) < ($1.line, $1.severity) }
        return reading
    }

    private static func sectionDiagnostics(of reading: ConfigReading, lineCount: Int) -> [ConfigDiagnostic] {
        var found: [ConfigDiagnostic] = []
        func add(_ severity: DiagnosticSeverity, _ line: Int, _ message: String, _ hint: String = "", _ category: DiagnosticCategory = .format) {
            found.append(ConfigDiagnostic(severity: severity, line: line, message: message, hint: hint, category: category))
        }
        let interfaces = reading.interfaces, peers = reading.peers
        if interfaces.isEmpty { add(.error, 1, "The [Interface] section is missing.", "Add [Interface] with PrivateKey and Address.", .syntax) }
        if interfaces.count > 1 { add(.error, interfaces[1].line, "Only one [Interface] section is allowed.", "Remove the extra one.", .syntax) }
        if peers.isEmpty { add(.error, lineCount, "The [Peer] section is missing.", "Without a peer there is no server to connect to.", .syntax) }

        func requiredKey(_ section: ConfigSection, _ key: String, _ label: String, _ kind: String) {
            guard let entry = section[key], !entry.value.isEmpty else {
                add(.error, section[key]?.line ?? section.line, "\(label) is missing.", "Set a valid WireGuard \(kind) key.", .required)
                return
            }
            if isPlaceholder(entry.value) {
                add(.error, entry.line, "Replace \(entry.value) with a real value.", "The template placeholder is not a valid key.")
            } else if !isKey(entry.value) {
                add(.error, entry.line, "\(label) is not a valid WireGuard key.", "A key is 44 characters of Base64 ending in “=”.")
            }
        }

        if let section = interfaces.first {
            requiredKey(section, "privatekey", "PrivateKey", "private")
            if let address = section["address"], !address.value.isEmpty {
                let bad = list(address.value).filter { !isAddressOrCIDR($0) }
                if !bad.isEmpty { add(.error, address.line, "Address has an invalid entry: \(bad.joined(separator: ", ")).", "Write each address like 10.0.0.2/24.") }
            } else {
                add(.error, section["address"]?.line ?? section.line, "Address is missing.", "Specify at least one interface address (e.g. 10.0.0.2/24).", .required)
            }
            if let dns = section["dns"], !dns.value.isEmpty {
                let bad = list(dns.value).filter { !WireGuardDNS.isAddress($0) && WireGuardDNS.normalizedDomain($0) == nil }
                if !bad.isEmpty { add(.error, dns.line, "DNS has an invalid entry: \(bad.joined(separator: ", ")).", "Use IP addresses, then search domains.") }
            } else {
                add(.warning, section.line, ConfigWarning.missingDNS.rawValue, "Name lookups will use the network’s own DNS.", .note)
            }
            if let port = section["listenport"], !(Int(port.value).map { (1...65535).contains($0) } ?? false) {
                add(.error, port.line, "ListenPort must be 1 to 65535.", "")
            }
        }

        for section in peers.dropFirst() {
            add(.warning, section.line, "Multiple peers found — only the first peer is used.",
                "Remove the others, or create a separate tunnel for each.", .note)
        }
        for (index, section) in peers.enumerated() {
            requiredKey(section, "publickey", "PublicKey", "public")
            if let psk = section["presharedkey"], !psk.value.isEmpty, !isKey(psk.value), !isPlaceholder(psk.value) {
                add(.error, psk.line, "PresharedKey is not a valid WireGuard key.", "A key is 44 characters of Base64 ending in “=”.")
            }
            if let endpoint = section["endpoint"], !endpoint.value.isEmpty {
                if !isEndpoint(endpoint.value) { add(.error, endpoint.line, "Endpoint must be host:port.", "Example: vpn.example.com:51820.") }
            } else {
                add(.warning, section["endpoint"]?.line ?? section.line, ConfigWarning.missingEndpoint.rawValue,
                    "You can save, but the tunnel can’t connect until you add host:port, e.g. vpn.example.com:51820.", .note)
            }
            if let allowed = section["allowedips"], !allowed.value.isEmpty {
                let ranges = list(allowed.value), bad = ranges.filter { !isAddressOrCIDR($0) }
                if !bad.isEmpty {
                    add(.error, allowed.line, "AllowedIPs has an invalid range: \(bad.joined(separator: ", ")).", "Write each range like 10.0.0.0/24.")
                } else if index == 0 {
                    let addresses = interfaces.first.map { list($0.value("address")) } ?? []
                    if ranges.contains("0.0.0.0/0") { add(.info, allowed.line, ConfigWarning.fullTunnel.rawValue, "All traffic will go through this tunnel.", .note) }
                    if ranges.contains("0.0.0.0/0"), !addresses.contains(where: { $0.contains(".") }) {
                        add(.warning, allowed.line, ConfigWarning.ipv4RoutedWithoutAddress.rawValue, "", .note)
                    }
                    if ranges.contains("::/0"), !addresses.contains(where: { $0.contains(":") }) {
                        add(.warning, allowed.line, ConfigWarning.ipv6RoutedWithoutAddress.rawValue, "", .note)
                    }
                }
            } else {
                add(.error, section["allowedips"]?.line ?? section.line, "AllowedIPs is missing.", "Choose which traffic goes through the tunnel, e.g. 0.0.0.0/0.", .required)
            }
            if let keepalive = section["persistentkeepalive"], !(Int(keepalive.value).map { (0...65535).contains($0) } ?? false) {
                add(.error, keepalive.line, "PersistentKeepalive must be a number of seconds.", "")
            }
        }
        return found
    }
}

// MARK: - Basic form

/// The fields of the basic form, and the conversion to and from a `.conf` text.
nonisolated struct TunnelFormFields: Equatable {
    var name = "", privateKey = "", address = "", dns = "", searchDomains = ""
    var peerPublicKey = "", presharedKey = "", endpoint = "", allowedIPs = "", keepalive = ""

    /// The `.conf` the form writes. `maskingKeys` is for previews: keys are never shown there.
    func config(maskingKeys: Bool = false) -> String {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces) }
        func secret(_ value: String) -> String { maskingKeys ? "(hidden)" : trimmed(value) }
        var lines = ["[Interface]", "PrivateKey = \(privateKey.isEmpty ? "" : secret(privateKey))", "Address = \(trimmed(address))"]
        let dnsLine = WireGuardDNS.compose(servers: dns, searchDomains: searchDomains).line
        if !dnsLine.isEmpty { lines.append("DNS = \(dnsLine)") }
        lines += ["", "[Peer]", "PublicKey = \(trimmed(peerPublicKey))"]
        if !presharedKey.isEmpty { lines.append("PresharedKey = \(secret(presharedKey))") }
        if !trimmed(endpoint).isEmpty { lines.append("Endpoint = \(trimmed(endpoint))") }
        lines.append("AllowedIPs = \(trimmed(allowedIPs))")
        if !trimmed(keepalive).isEmpty { lines.append("PersistentKeepalive = \(trimmed(keepalive))") }
        return lines.joined(separator: "\n")
    }

    /// The form's fields from a config, or why the form cannot hold it without losing something.
    static func read(config text: String) -> Result<TunnelFormFields, FormConversionFailure> {
        let reading = ConfigDiagnostics.read(text)
        let errors = reading.errors.count
        if errors > 0 { return .failure(.init(reason: "It still has \(errors) error\(errors == 1 ? "" : "s") to fix.")) }
        if reading.diagnostics.contains(where: { $0.message.contains(" appears twice in [") }) {
            return .failure(.init(reason: "A setting appears twice, and the form can keep only one."))
        }
        if reading.hasComments { return .failure(.init(reason: "It has comments, which the form cannot keep.")) }
        guard reading.interfaces.count == 1, reading.peers.count <= 1 else {
            return .failure(.init(reason: reading.interfaces.count != 1 ? "It does not have exactly one [Interface] section." : "It has more than one peer."))
        }
        let interface = reading.interfaces[0], peer = reading.peers.first ?? ConfigSection(name: "Peer", line: 0)
        let extra = interface.entries.keys.filter { !["privatekey", "address", "dns"].contains($0) }
            + peer.entries.keys.filter { !["publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive"].contains($0) }
        if !extra.isEmpty { return .failure(.init(reason: "It uses settings the form does not have: \(extra.sorted().joined(separator: ", ")).")) }
        let entries = ConfigDiagnostics.list(interface.value("dns"))
        var fields = TunnelFormFields()
        fields.privateKey = interface.value("privatekey")
        fields.address = interface.value("address")
        fields.dns = WireGuardDNS.servers(entries).joined(separator: ", ")
        fields.searchDomains = WireGuardDNS.searchDomains(entries).joined(separator: ", ")
        fields.peerPublicKey = peer.value("publickey")
        fields.presharedKey = peer.value("presharedkey")
        fields.endpoint = peer.value("endpoint")
        fields.allowedIPs = peer.value("allowedips")
        fields.keepalive = peer.value("persistentkeepalive")
        return .success(fields)
    }
}

nonisolated struct FormConversionFailure: Error, Equatable { let reason: String }

/// What is wrong with each field, whether the tunnel can be saved, and whether it can connect.
nonisolated struct TunnelFormChecks {
    enum Field: CaseIterable { case name, privateKey, address, dns, searchDomains, peerPublicKey, presharedKey, endpoint, allowedIPs, keepalive }

    var problems: [Field: String] = [:]
    var warnings: [String] = []
    var endpointMissing = false

    /// Needs a name, keys, an address and AllowedIPs; a missing endpoint only stops connecting.
    var canSave: Bool { problems.isEmpty }
    var canConnect: Bool { canSave && !endpointMissing }

    static func nameProblem(_ name: String, existing: [String]) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the tunnel a name." }
        if name.range(of: "^[A-Za-z0-9 ._-]{1,40}$", options: .regularExpression) == nil {
            return "Use letters, numbers, spaces, dots, dashes and underscores (40 characters at most)."
        }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return "A tunnel called “\(name)” already exists." }
        return nil
    }

    /// `otherFullTunnels` are the connected tunnels that already route all traffic.
    init(_ f: TunnelFormFields, existingNames: [String], otherFullTunnels: [String] = []) {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces) }
        let keyMessage = "A WireGuard key is 44 characters of Base64 ending in “=”."
        let key = trimmed(f.privateKey), pub = trimmed(f.peerPublicKey), psk = trimmed(f.presharedKey)
        let endpoint = trimmed(f.endpoint), keepalive = trimmed(f.keepalive)
        var found: [Field: String?] = [:]
        found[.name] = Self.nameProblem(f.name, existing: existingNames)
        found[.privateKey] = key.isEmpty ? "Add a private key, or generate one." : ConfigDiagnostics.isKey(key) ? nil : keyMessage
        let addresses = ConfigDiagnostics.list(f.address)
        found[.address] = addresses.isEmpty ? "Add the address of this device inside the tunnel, such as 10.0.0.2/24."
            : addresses.allSatisfy(ConfigDiagnostics.isAddressOrCIDR) ? nil : "Write each address like 10.0.0.2/24."
        let badServers = ConfigDiagnostics.list(f.dns).filter { !ConfigDiagnostics.isAddress($0) }
        found[.dns] = badServers.isEmpty ? nil : "Not an IP address: \(badServers.joined(separator: ", ")). Names can’t be used here."
        let invalidDomains = WireGuardDNS.compose(servers: "", searchDomains: f.searchDomains).invalidDomains
        found[.searchDomains] = invalidDomains.isEmpty ? nil : "Not a valid domain: \(invalidDomains.joined(separator: ", "))"
        found[.peerPublicKey] = pub.isEmpty ? "Required: the server’s public key." : ConfigDiagnostics.isKey(pub) ? nil : keyMessage
        found[.presharedKey] = psk.isEmpty || ConfigDiagnostics.isKey(psk) ? nil : keyMessage
        endpointMissing = endpoint.isEmpty
        found[.endpoint] = endpoint.isEmpty || ConfigDiagnostics.isEndpoint(endpoint) ? nil : "Write it as host:port, with a port from 1 to 65535."
        let ranges = ConfigDiagnostics.list(f.allowedIPs)
        found[.allowedIPs] = ranges.isEmpty ? "Required: which traffic goes through the tunnel (0.0.0.0/0 for everything)."
            : ranges.allSatisfy(ConfigDiagnostics.isAddressOrCIDR) ? nil : "Write each range like 10.0.0.0/24 or 0.0.0.0/0."
        found[.keepalive] = keepalive.isEmpty || Int(keepalive).map({ (0...65535).contains($0) }) == true ? nil : "A number of seconds from 0 to 65535."
        for (field, message) in found { if let message { problems[field] = message } }

        let full = ranges.contains("0.0.0.0/0")
        if full, !otherFullTunnels.isEmpty {
            warnings.append("This tunnel routes all traffic, and \(otherFullTunnels.map { "“\($0)”" }.joined(separator: ", ")) already does. Connecting both makes them compete for the default route.")
        }
        if full, !ranges.contains("::/0") { warnings.append("0.0.0.0/0 covers IPv4 only. Add ::/0 too, or IPv6 traffic can bypass the tunnel (IPv6 leak).") }
        if full, keepalive.isEmpty { warnings.append("No keepalive. Behind a NAT or firewall the connection can go quiet; 25 seconds is the usual choice.") }
    }
}
