import Foundation

@main
struct RuntimeUpdateTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RuntimeUpdateTests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("runtime-update-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled")
        let installed = root.appendingPathComponent("installed")
        for directory in [bundled, installed] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = root.appendingPathComponent("tool.c")
        let executable = root.appendingPathComponent("tool")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-arch", "x86_64", source.path, "-o", executable.path])
        let verifier = WireGuardManifestVerifier()

        func reset() throws {
            for (directory, identity) in [(bundled, "example.bundle"), (installed, "example.installed")] {
                for name in ["wg", "wireguard-go"] {
                    let file = directory.appendingPathComponent(name)
                    try? fm.removeItem(at: file)
                    try fm.copyItem(at: executable, to: file)
                    try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identity, file.path])
                }
                try Data("#!/bin/bash\nexit 0\n".utf8).write(to: directory.appendingPathComponent("wg-quick"))
                try manifest(directory)
            }
        }
        func manifest(_ directory: URL, version: String = "fixture-v1", architectures: [String] = ["arm64", "x86_64"], revision: String = String(repeating: "a", count: 40), reverseArtifacts: Bool = false) throws {
            let artifacts = try ["wg", "wg-quick", "wireguard-go"].map { name in
                let file = directory.appendingPathComponent(name)
                return WireGuardManifest.Artifact(name: name, version: version,
                    sourceURL: "https://example.invalid/upstream.git", revision: revision,
                    architectures: architectures, sha256: try verifier.sha256(of: file),
                    size: Int64(try Data(contentsOf: file).count))
            }
            let manifest = WireGuardManifest(schemaVersion: 1, generatedAt: "2026-10-15T00:00:00Z",
                source: "Synthetic tools", patches: [], artifacts: reverseArtifacts ? artifacts.reversed() : artifacts)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        }
        func matches() -> Bool {
            verifier.runtimesMatch(bundledDirectory: bundled,
                bundledManifestURL: bundled.appendingPathComponent("manifest.json"),
                installedDirectory: installed, installedManifestURL: installed.appendingPathComponent("manifest.json"))
        }

        try reset()
        let bundledHash = try verifier.sha256(of: bundled.appendingPathComponent("wg"))
        let installedHash = try verifier.sha256(of: installed.appendingPathComponent("wg"))
        expect(bundledHash != installedHash, "the fixture must contain different signed bytes")
        expect(matches(), "signing-only changes must not require reinstalling verified tools")
        try manifest(installed, architectures: ["x86_64", "arm64"])
        expect(matches(), "manifest architecture ordering must not require reinstallation")
        try manifest(installed, reverseArtifacts: true)
        expect(matches(), "manifest artifact ordering must not require reinstallation")
        try manifest(installed, architectures: ["arm64"])
        expect(!matches(), "an architecture change must require an update")
        try manifest(installed, revision: String(repeating: "b", count: 40))
        expect(!matches(), "a changed source revision must require an update")
        try manifest(installed, version: "fixture-v0")
        expect(!matches(), "a different tool version must require an update")

        try reset()
        try Data("#!/bin/bash\nexit 1\n".utf8).write(to: installed.appendingPathComponent("wg-quick"))
        try manifest(installed)
        expect(!matches(), "a changed wg-quick script must require an update")
        try reset()
        try Data("int main(void) { return 1; }\n".utf8).write(to: source)
        let changed = root.appendingPathComponent("changed")
        try run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-arch", "x86_64", source.path, "-o", changed.path])
        try fm.removeItem(at: installed.appendingPathComponent("wg"))
        try fm.copyItem(at: changed, to: installed.appendingPathComponent("wg"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "example.installed", installed.appendingPathComponent("wg").path])
        try manifest(installed)
        expect(!matches(), "a changed executable with the same version must require an update")

        try reset()
        try Data("tampered".utf8).write(to: installed.appendingPathComponent("wg"))
        expect(!matches(), "installed integrity failure must never be accepted")
        try reset()
        try fm.removeItem(at: installed.appendingPathComponent("wireguard-go"))
        expect(!matches(), "a missing executable must never be accepted")
        try reset()
        try fm.removeItem(at: installed.appendingPathComponent("wg"))
        try fm.createSymbolicLink(at: installed.appendingPathComponent("wg"), withDestinationURL: executable)
        expect(!matches(), "a symlink must never count as an installed executable")
        try reset()
        try Data("not a manifest".utf8).write(to: bundled.appendingPathComponent("manifest.json"))
        expect(!matches(), "an invalid bundle manifest must fail closed")
        try reset()
        let before = try [bundled, installed].flatMap { directory in
            try ["wg", "wireguard-go"].map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        }
        expect(matches(), "a final valid signing-only update must match")
        let after = try [bundled, installed].flatMap { directory in
            try ["wg", "wireguard-go"].map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        }
        expect(before == after, "signature comparison must not modify bundled or installed executables")
        print("PASS: tool updates ignore signatures while detecting payload, script, version, and integrity changes")
    }
}
