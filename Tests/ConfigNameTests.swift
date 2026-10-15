import Foundation

@main
struct ConfigNameTests {
    static func main() {
        let names = ["Office VPN", "Office_VPN", "東京 VPN 🔒", "VPN 👩‍💻", "vpn.example", "vpn.conf", ".conf", "vpn.", ".", "../Office/VPN", String(repeating: "a", count: 50)]
        for name in names {
            guard ConfigName.displayName(name) == name,
                  ConfigStorageService.displayName(for: name) == name else {
                print("FAIL: Shared tunnel display name changed: \(name)")
                exit(1)
            }
            let alias = ConfigName.fileBaseName(name)
            guard alias == ConfigStorageService.fileBaseName(for: name),
                  alias.range(of: "^[a-zA-Z0-9_=+.-]{1,15}$", options: .regularExpression) != nil,
                  !alias.contains("..") else { fatalError("Personal and shared aliases disagree or are unsafe") }
        }
        guard ConfigName.displayName("  Office VPN  \n") == "Office VPN" else { fatalError("Display name was not trimmed") }
        guard ConfigName.fileBaseName("Café") == ConfigName.fileBaseName("Cafe\u{301}") else {
            fatalError("Equivalent Unicode display names use different shared aliases")
        }
        print("PASS: shared tunnel display names are preserved and aliases agree with personal tunnels")
    }
}
