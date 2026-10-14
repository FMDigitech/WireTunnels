import Foundation

@main
struct TunnelConfigLoadingTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = "[Interface]\nPrivateKey = synthetic\nListenPort = 51820\nMTU = 1420\n# keep this comment\n[Peer]\nPublicKey = synthetic\n"
        let personalURL = root.appendingPathComponent("personal.conf")
        try contents.write(to: personalURL, atomically: true, encoding: .utf8)
        let state = TunnelConfigLoadingState()
        await state.load(configURL: personalURL, managedTunnelID: nil) { _ in
            fatalError("Personal editor requested privileged config access")
        }
        guard state.contents == contents, state.canEdit, state.error == nil else { fatalError("Personal config did not load intact") }
        let sharedID = UUID()
        await state.load(configURL: root.appendingPathComponent("unreadable.conf"), managedTunnelID: sharedID) { id in
            guard id == sharedID else { fatalError("Requested another shared tunnel's config") }
            return Data(contents.utf8)
        }
        guard state.contents == contents, state.canEdit else { fatalError("Shared editor did not load the original config through its helper") }
        await state.load(configURL: personalURL, managedTunnelID: sharedID) { _ in
            throw CocoaError(.userCancelled)
        }
        guard !state.canEdit, state.contents == nil, state.error != nil else { fatalError("Authorization failure exposed stale content or enabled Save") }
        await state.load(configURL: root.appendingPathComponent("missing.conf"), managedTunnelID: nil) { _ in Data() }
        guard !state.canEdit, state.error != nil else { fatalError("Missing personal config became a blank editable config") }
        await state.load(configURL: personalURL, managedTunnelID: sharedID) { _ in Data([0xff]) }
        guard !state.canEdit, state.error != nil else { fatalError("Invalid UTF-8 became a blank editable config") }
        await state.load(configURL: personalURL, managedTunnelID: nil) { _ in Data() }
        guard state.canEdit, state.error == nil, state.contents == contents else { fatalError("Retry did not clear the previous loading error") }
        print("PASS: config editor loads shared contents through authorization and prevents edits after load failures")
    }
}
