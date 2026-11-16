import Foundation

@main
struct ConfigDiagnosticsTests {
    static let key = String(repeating: "A", count: 43) + "="
    static let peerKey = String(repeating: "B", count: 43) + "="

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    static func main() {
        let valid = """
        [Interface]
        PrivateKey = \(key)
        Address = 10.0.0.2/24
        DNS = 1.1.1.1

        [Peer]
        PublicKey = \(peerKey)
        Endpoint = vpn.example.com:51820
        AllowedIPs = 10.0.0.0/24
        """
        let good = ConfigDiagnostics.read(valid)
        check(good.errors.isEmpty && good.warningCount == 0, "a complete config has no errors or warnings: \(good.diagnostics)")

        // Hooks are errors on their own line, with the same wording as the import check.
        let hook = ConfigDiagnostics.read(valid.replacingOccurrences(of: "DNS = 1.1.1.1", with: "postup = iptables -A FORWARD"))
        check(hook.errors.contains { $0.line == 4 && $0.message == "PostUp is not supported because it executes commands with root privileges" },
              "PostUp is an error on line 4: \(hook.diagnostics)")

        // Template placeholders are not keys.
        let template = ConfigDiagnostics.read("[Interface]\nPrivateKey = <PRIVATE_KEY>\nAddress = 10.8.0.2/24\n\n[Peer]\nPublicKey = <SERVER_PUBLIC_KEY>\nAllowedIPs = 0.0.0.0/0")
        check(template.errors.contains { $0.message == "Replace <PRIVATE_KEY> with a real value." }, "placeholders are errors")

        // A missing endpoint is only a warning: it saves but cannot connect.
        let noEndpoint = ConfigDiagnostics.read(valid.replacingOccurrences(of: "Endpoint = vpn.example.com:51820\n", with: ""))
        check(noEndpoint.errors.isEmpty && noEndpoint.hasMissingEndpoint, "missing endpoint is a warning")

        // Missing peer values are errors; the sections themselves are required.
        let bare = ConfigDiagnostics.read("[Interface]\nAddress = 10.0.0.2/24\n\n[Peer]\nEndpoint = vpn.example.com:51820")
        let messages = Set(bare.errors.map(\.message))
        check(messages.isSuperset(of: ["PrivateKey is missing.", "PublicKey is missing.", "AllowedIPs is missing."]), "required values: \(messages)")
        check(ConfigDiagnostics.read("").errors.map(\.message).contains("The [Interface] section is missing."), "empty text has no interface")
        check(ConfigDiagnostics.read("PrivateKey = x").errors.contains { $0.message.contains("outside any section") }, "keys need a section")
        check(ConfigDiagnostics.read("[Interface]\nnonsense").errors.contains { $0.line == 2 && $0.message == "This line is not valid." }, "lines without = are errors")

        // Full tunnel: a note, and a leak warning when the Address has no matching family.
        let full = ConfigDiagnostics.read(valid.replacingOccurrences(of: "10.0.0.0/24", with: "0.0.0.0/0, ::/0"))
        check(full.diagnostics.contains { $0.severity == .info && $0.message == ConfigWarning.fullTunnel.rawValue }, "full tunnel note")
        check(full.diagnostics.contains { $0.message == ConfigWarning.ipv6RoutedWithoutAddress.rawValue }, "IPv6 leak warning")

        // A second peer and a repeated key are warnings, a trailing comment is not part of the value.
        let twice = ConfigDiagnostics.read(valid + "\nAllowedIPs = 10.1.0.0/24 # second\n\n[Peer]\nPublicKey = \(key)\nAllowedIPs = 10.2.0.0/24")
        check(twice.diagnostics.contains { $0.message == "AllowedIPs appears twice in [Peer]." }, "repeated key")
        check(twice.diagnostics.contains { $0.message.hasPrefix("Multiple peers found") }, "second peer")
        check(ConfigDiagnostics.read(valid.replacingOccurrences(of: "10.0.0.2/24", with: "10.0.0.2/24 # home")).errors.isEmpty, "trailing comment ignored")

        // The gutter marks the worst problem of a line and ignores notes.
        check(hook.severity(onLine: 4) == .error && hook.severity(onLine: 1) == .warning && hook.severity(onLine: 2) == nil, "gutter severity")

        // AmneziaWG keys are known settings, not typos.
        let amnezia = ConfigDiagnostics.read(valid.replacingOccurrences(of: "DNS", with: "Jc = 4\nDNS"))
        check(!amnezia.diagnostics.contains { $0.message.contains("not a known") }, "AmneziaWG keys are recognised")

        // Form round trip: what the form writes, it reads back.
        var fields = TunnelFormFields()
        fields.privateKey = key; fields.address = "10.0.0.2/24"; fields.dns = "1.1.1.1"; fields.searchDomains = "office.lan"
        fields.peerPublicKey = peerKey; fields.endpoint = "vpn.example.com:51820"; fields.allowedIPs = "0.0.0.0/0, ::/0"; fields.keepalive = "25"
        guard case .success(let back) = TunnelFormFields.read(config: fields.config()) else { check(false, "the form reads its own config"); return }
        check(back == fields, "round trip keeps every field: \(back)")
        let preview = fields.config(maskingKeys: true)
        check(!preview.contains(key) && preview.contains("PrivateKey = (hidden)"), "previews hide keys")

        // The form refuses what it would lose.
        func refusal(_ text: String) -> String? { if case .failure(let f) = TunnelFormFields.read(config: text) { return f.reason }; return nil }
        check(refusal(valid + "\n# note")?.contains("comments") == true, "comments")
        check(refusal(valid.replacingOccurrences(of: "DNS", with: "MTU = 1280\nDNS"))?.contains("mtu") == true, "settings the form lacks")
        check(refusal("[Interface]")?.contains("error") == true, "errors")
        check(refusal(valid + "\n[Peer]\nPublicKey = \(peerKey)\nAllowedIPs = 10.9.0.0/24")?.contains("more than one peer") == true, "two peers")

        // Saving needs a name, keys, address and AllowedIPs; endpoint only gates connecting.
        var checks = TunnelFormChecks(fields, existingNames: [])
        check(Set(checks.problems.keys) == [.name], "only the name is missing: \(checks.problems)")
        fields.name = "Office"
        checks = TunnelFormChecks(fields, existingNames: ["other"])
        check(checks.canSave && checks.canConnect && checks.warnings.isEmpty, "a complete form saves and connects: \(checks.problems)")
        fields.endpoint = ""
        checks = TunnelFormChecks(fields, existingNames: [], otherFullTunnels: ["Home"])
        check(checks.canSave && !checks.canConnect && checks.endpointMissing, "no endpoint: save yes, connect no")
        check(checks.warnings.contains { $0.contains("“Home”") }, "competing full tunnel warning")
        fields.peerPublicKey = ""
        check(!TunnelFormChecks(fields, existingNames: []).canSave, "peer public key is required to save")
        check(TunnelFormChecks.nameProblem("office", existing: ["Office"]) != nil, "names are unique, ignoring case")
        print("PASS: config diagnostics, form conversion and save rules")
    }
}
