import Foundation

@main
struct ConfigStorageTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ConfigStorageService(configDirectory: root.appendingPathComponent("configs"))
        let names = ["Office VPN", "Office_VPN", "Prague (backup)", "東京 VPN 🔒", "VPN 👩‍💻", "../Office/VPN", "vpn.example", "vpn.conf", ".conf", "vpn.", ".", "a..b"]
        var paths = Set<String>()
        for name in names {
            let url: URL
            do {
                url = try storage.saveConfig(name: name, content: "config for \(name)")
            } catch {
                print("FAIL: Could not save display name \(name): \(error.localizedDescription)")
                exit(1)
            }
            let base = url.deletingPathExtension().lastPathComponent
            guard base.range(of: "^[a-zA-Z0-9_=+.-]{1,15}$", options: .regularExpression) != nil,
                  !url.lastPathComponent.contains(".."), url.deletingLastPathComponent() == root.appendingPathComponent("configs"),
                  paths.insert(url.path).inserted,
                  try storage.readConfig(at: url) == "config for \(name)" else {
                fatalError("Display names must use distinct, safe config files inside the config directory")
            }
            let updated = try storage.saveConfig(name: name, content: "edited", replacingExisting: true)
            guard updated == url else { fatalError("Editing a tunnel changed its config alias") }
            do {
                _ = try storage.saveConfig(name: name, content: "overwritten")
                fatalError("Saving a duplicate name overwrote a config")
            } catch ConfigStorageError.alreadyExists { }
        }
        let source = root.appendingPathComponent("Imported VPN (東京).conf")
        let accented = try storage.saveConfig(name: "Café", content: "accented config")
        do {
            _ = try storage.saveConfig(name: "Cafe\u{301}", content: "other config")
            print("FAIL: Canonically equivalent display names created separate config files")
            exit(1)
        } catch ConfigStorageError.alreadyExists { }
        let accentEdit = try storage.saveConfig(name: "Cafe\u{301}", content: "edited accent", replacingExisting: true)
        guard accentEdit == accented,
              try storage.readConfig(at: accented) == "edited accent" else {
            fatalError("Equivalent Unicode name changed the alias during editing")
        }
        try "imported config".write(to: source, atomically: true, encoding: .utf8)
        let imported = try storage.importConfig(from: source)
        guard try storage.readConfig(at: imported) == "imported config" else { fatalError("Import lost config contents") }
        let permissions = try FileManager.default.attributesOfItem(atPath: imported.path)
        guard (permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { fatalError("Import lost private permissions") }
        for name in ["", "   ", "\n", "VPN\u{0}bad"] {
            do {
                _ = try storage.saveConfig(name: name, content: "invalid")
                fatalError("Accepted an empty name or control character")
            } catch ConfigStorageError.invalidName { }
        }
        guard ConfigStorageService.fileBaseName(for: "vpn") == "vpn",
              ConfigStorageService.fileBaseName(for: "vpn.example") == "vpn.example",
              ConfigStorageService.fileBaseName(for: String(repeating: "a", count: 50)).utf8.count <= 15 else {
            fatalError("Existing ASCII aliases or long-name limits changed")
        }
        print("PASS: display names save, import, and edit using distinct, private, interface-safe config files")
    }
}
