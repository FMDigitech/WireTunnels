import Foundation

@main
struct ToolInstallerTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ToolInstaller.Owner(uid: getuid(), gid: getgid())
        let genuine = ["wg": "genuine wg\n", "wg-quick": "genuine wg-quick\n", "wireguard-go": "genuine wireguard-go\n"]

        let source = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, contents) in genuine { try contents.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let tools = try genuine.keys.sorted().map { name in
            ToolInstaller.Tool(name: name, check: .sha256(try ToolInstaller.sha256(of: source.appendingPathComponent(name))))
        }
        let systemRoot = root.appendingPathComponent("system", isDirectory: true)
        let bin = systemRoot.appendingPathComponent("bin", isDirectory: true)
        var events: [(isError: Bool, message: String)] = []
        let installer = ToolInstaller(tools: tools, source: { source }, binDirectory: bin, owner: owner,
                                      onEvent: { events.append(($0, $1)) })
        func expectInstalled(_ name: String, _ contents: String?, _ message: String) throws {
            let actual = try String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8)
            precondition(actual == contents, message)
        }
        func fails(_ message: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(message) } catch {}
        }

        fails("Missing tools must not verify") { try installer.verifyInstalled() }
        try installer.ensureInstalled()
        try installer.verifyInstalled()
        for (name, contents) in genuine { try expectInstalled(name, contents, "\(name) must be installed from the source") }
        precondition(events.map(\.isError) == [false, false] && events[0].message.hasPrefix("Installing"),
                     "A first install must be reported as an install, not as a failed check")

        // A tampered installed tool fails verification and is replaced by the genuine one.
        try "tampered\n".write(to: bin.appendingPathComponent("wg-quick"), atomically: true, encoding: .utf8)
        fails("A tampered tool must not verify") { try installer.verifyInstalled() }
        try installer.ensureInstalled(["wg"])
        try expectInstalled("wg-quick", "tampered\n", "Checking wg alone must not touch wg-quick")
        events.removeAll()
        try installer.ensureInstalled()
        try expectInstalled("wg-quick", genuine["wg-quick"], "A tampered tool must be reinstalled")
        precondition(events.count == 2 && events[0].isError && events[0].message.contains("wg-quick") && !events[1].isError,
                     "A tampered tool must be reported as an error naming it, then the reinstall")

        // A source file that doesn't match its anchor leaves bin/ untouched.
        try "replaced\n".write(to: source.appendingPathComponent("wireguard-go"), atomically: true, encoding: .utf8)
        try "tampered\n".write(to: bin.appendingPathComponent("wg"), atomically: true, encoding: .utf8)
        fails("A source failing verification must not install") { try installer.ensureInstalled() }
        try expectInstalled("wg", "tampered\n", "A failed install must leave bin/ untouched")
        try expectInstalled("wireguard-go", genuine["wireguard-go"], "A failed install must not copy unverified files")

        // A symlinked source is rejected, even when its target matches the anchor.
        let outside = root.appendingPathComponent("outside-wireguard-go")
        try genuine["wireguard-go"]!.write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: source.appendingPathComponent("wireguard-go"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("wireguard-go"), withDestinationURL: outside)
        do {
            try installer.ensureInstalled()
            preconditionFailure("A symlinked source must not install")
        } catch ToolInstallError.notRegularFile(let name) {
            precondition(name == "wireguard-go")
        }
        try expectInstalled("wg", "tampered\n", "A rejected symlink must leave bin/ untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: systemRoot.path).filter { $0.hasPrefix(".install-") }
        precondition(leftovers.isEmpty, "A failed install must remove its staging folder")
        try FileManager.default.removeItem(at: source.appendingPathComponent("wireguard-go"))
        try genuine["wireguard-go"]!.write(to: source.appendingPathComponent("wireguard-go"), atomically: true, encoding: .utf8)
        try installer.ensureInstalled()

        // A staging folder left by a helper stopped mid-install is removed by the next install.
        let interrupted = systemRoot.appendingPathComponent(".install-interrupted/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try genuine["wg"]!.write(to: interrupted.appendingPathComponent("wg"), atomically: true, encoding: .utf8)
        try "tampered\n".write(to: bin.appendingPathComponent("wg"), atomically: true, encoding: .utf8)
        try installer.ensureInstalled()
        let stale = try FileManager.default.contentsOfDirectory(atPath: systemRoot.path).filter { $0.hasPrefix(".install-") }
        precondition(stale.isEmpty, "An install must remove staging folders left by an interrupted one")

        // Tools or folders others can write could be swapped after the check.
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: bin.appendingPathComponent("wg").path)
        fails("A group-writable tool must not verify") { try installer.verifyInstalled(["wg"]) }
        try installer.ensureInstalled()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: bin.path)
        fails("A world-writable bin/ must not verify") { try installer.verifyInstalled() }
        try installer.ensureInstalled()
        try installer.verifyInstalled()
        let linkedBin = systemRoot.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedBin, withDestinationURL: bin)
        let linkedInstaller = ToolInstaller(tools: tools, source: { source }, binDirectory: linkedBin, owner: owner)
        fails("A symlinked bin/ must not verify") { try linkedInstaller.verifyInstalled() }
        fails("Unknown tools must be rejected") { try installer.verifyInstalled(["sh"]) }

        // Code signatures are checked against the requirement, not just for validity.
        let signed = root.appendingPathComponent("signed", isDirectory: true)
        try FileManager.default.createDirectory(at: signed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: signed.appendingPathComponent("wg"))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--identifier", "wg", signed.appendingPathComponent("wg").path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        precondition(codesign.terminationStatus == 0, "codesign must sign the fixture")
        func signatureInstaller(_ requirement: String, into name: String) -> ToolInstaller {
            ToolInstaller(tools: [ToolInstaller.Tool(name: "wg", check: .codeSignature(requirement: requirement))],
                          source: { signed }, binDirectory: root.appendingPathComponent(name, isDirectory: true), owner: owner)
        }
        try signatureInstaller("identifier \"wg\"", into: "signed-bin").ensureInstalled()
        fails("A different identifier must be rejected") {
            try signatureInstaller("identifier \"wireguard-go\"", into: "wrong-identifier-bin").ensureInstalled()
        }
        fails("An ad-hoc signature must not satisfy the team requirement") {
            try signatureInstaller("anchor apple generic and identifier \"wg\" and certificate leaf[subject.OU] = \"48W4Z4X56T\"",
                                   into: "team-bin").ensureInstalled()
        }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("team-bin").path),
                     "A rejected signature must not create bin/")

        // The source is always the app bundle the helper itself was launched from.
        let helper = URL(fileURLWithPath: "/Applications/WireTunnels.app/Contents/Library/LaunchDaemons/com.fmdigitech.WireTunnels.helper")
        let toolsDirectory = try ToolInstaller.bundledToolsDirectory(executable: helper)
        precondition(toolsDirectory.path == "/Applications/WireTunnels.app/Contents/Resources/wireguard")
        for executable in ["/usr/local/bin/com.fmdigitech.WireTunnels.helper",
                           "/Applications/WireTunnels.app/Contents/MacOS/com.fmdigitech.WireTunnels.helper"] {
            fails("A helper outside an app's LaunchDaemons must not find tools") {
                _ = try ToolInstaller.bundledToolsDirectory(executable: URL(fileURLWithPath: executable))
            }
        }
        print("PASS: the helper installs only anchored regular files from its own bundle and leaves bin/ untouched on failure")
    }
}
