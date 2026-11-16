import Foundation

@main
struct ProxySettingsTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() throws {
        // Validation
        expect(ProxySettings(mode: .off).problem == nil, "no proxy needs nothing else")
        var manual = ProxySettings(mode: .manual)
        expect(manual.problem != nil, "a manual proxy with no server must be refused")
        manual.web = ProxyEndpoint(host: "proxy.example.com", port: 8080)
        expect(manual.problem == nil, "one valid server is enough")
        manual.socks = ProxyEndpoint(host: "10.0.0.2", port: 1080)
        manual.secureWeb = ProxyEndpoint(host: "fd00::5", port: 3128)
        expect(manual.problem == nil, "names, IPv4 and IPv6 literals must be accepted")
        for bad in ["", "-oProxy", "a b", "host;rm", "ho$t", String(repeating: "a", count: 254), "http://x"] {
            var candidate = ProxySettings(mode: .manual)
            candidate.web = ProxyEndpoint(host: bad, port: 80)
            expect(candidate.problem != nil, "host \"\(bad)\" must be refused")
        }
        for port in [0, -1, 65536] {
            var candidate = ProxySettings(mode: .manual)
            candidate.web = ProxyEndpoint(host: "p.example.com", port: port)
            expect(candidate.problem != nil, "port \(port) must be refused")
        }
        manual.bypass = ["*.local", "169.254/16", "10.0.0.0/8", "example.com"]
        expect(manual.problem == nil, "usual bypass entries must be accepted")
        manual.bypass = ["ok.example.com", "bad entry"]
        expect(manual.problem != nil, "a bypass entry with a space must be refused")
        manual.bypass = Array(repeating: "a.example.com", count: ProxySettings.maxBypassEntries + 1)
        expect(manual.problem != nil, "too many bypass entries must be refused")

        var pac = ProxySettings(mode: .automatic)
        expect(pac.problem != nil, "a PAC proxy with no address must be refused")
        for good in ["http://wpad.example.com/proxy.pac", "https://cfg.example.com/a.pac?x=1"] {
            pac.autoConfigURL = good
            expect(pac.problem == nil, "\(good) must be accepted")
        }
        for bad in ["ftp://x.example.com/a.pac", "file:///etc/passwd", "javascript:alert(1)", "https://", "https://a b.example.com", "https://x.example.com/\u{7}"] {
            pac.autoConfigURL = bad
            expect(pac.problem != nil, "\(bad) must be refused")
        }

        // What reaches the system: every flag written, unrelated keys kept
        let existing: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "old.example.com", "HTTPPort": 3128,
                                       "SOCKSEnable": 1, "SOCKSProxy": "oldsocks", "SOCKSPort": 1080,
                                       "FTPPassive": 1, "ExceptionsList": ["keep.me"]]
        manual.bypass = ["*.local"]
        manual.secureWeb = nil
        manual.socks = nil
        let applied = manual.configuration(over: existing)
        expect(applied["HTTPEnable"] as? Int == 1 && applied["HTTPProxy"] as? String == "proxy.example.com" && applied["HTTPPort"] as? Int == 8080,
               "the HTTP proxy must be set")
        expect(applied["SOCKSEnable"] as? Int == 0, "a SOCKS proxy the profile does not use must be switched off, not left on")
        expect(applied["HTTPSEnable"] as? Int == 0 && applied["ProxyAutoConfigEnable"] as? Int == 0, "unused proxies must be off")
        expect(applied["ExceptionsList"] as? [String] == ["*.local"], "manual mode owns the bypass list")
        expect(applied["FTPPassive"] as? Int == 1, "settings a profile does not own must stay")

        let off = ProxySettings(mode: .off).configuration(over: existing)
        expect(off["HTTPEnable"] as? Int == 0 && off["SOCKSEnable"] as? Int == 0 && off["ProxyAutoConfigEnable"] as? Int == 0,
               "no proxy must switch every proxy off")
        expect(off["ExceptionsList"] as? [String] == ["keep.me"], "no proxy must not rewrite the bypass list")
        expect(ProxySettings(mode: .off).configuration(over: [:])["ProxyAutoDiscoveryEnable"] == nil,
               "no proxy on a service with no auto-discovery must not add one")

        pac.autoConfigURL = "https://cfg.example.com/a.pac"
        let auto = pac.configuration(over: existing)
        expect(auto["ProxyAutoConfigEnable"] as? Int == 1 && auto["ProxyAutoConfigURLString"] as? String == pac.autoConfigURL,
               "a PAC file must be set")
        expect(auto["HTTPEnable"] as? Int == 0 && auto["SOCKSEnable"] as? Int == 0, "a PAC profile must switch manual proxies off")
        expect(manual.configuration(over: [:])["ProxyAutoDiscoveryEnable"] as? Int == 0, "a profile's own proxy must turn auto-discovery off")

        // Journal: the previous settings survive a round trip, and "had none" stays distinct
        let journal = try ProxyJournal(serviceID: "ABCD-1234", previous: existing)
        let decoded = try JSONDecoder().decode(ProxyJournal.self, from: JSONEncoder().encode(journal))
        expect(decoded == journal, "a journal must survive JSON")
        let restored = decoded.previousConfiguration
        expect(restored?["HTTPProxy"] as? String == "old.example.com" && restored?["HTTPPort"] as? Int == 3128
               && restored?["ExceptionsList"] as? [String] == ["keep.me"], "the previous settings must come back unchanged")
        let none = try ProxyJournal(serviceID: "ABCD-1234", previous: nil)
        expect(none.previousConfiguration == nil && none.previous == nil, "a service that had no proxy settings must restore to none")
        // Applying twice must start from the original, never from the first profile's result
        let secondProfile = ProxySettings(mode: .off).configuration(over: decoded.previousConfiguration ?? [:])
        expect(secondProfile["HTTPPort"] as? Int == 3128, "a second profile must be built on the user's settings")

        // Saved in a profile's JSON and read back
        let settingsData = try JSONEncoder().encode(manual)
        let reread = try JSONDecoder().decode(ProxySettings.self, from: settingsData)
        expect(reread == manual, "settings must survive JSON")

        print("PASS: proxy settings are validated, written over the user's own settings and restorable")
    }
}
