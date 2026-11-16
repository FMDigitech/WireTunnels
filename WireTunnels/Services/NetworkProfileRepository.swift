import Foundation

/// Persists network profiles with the same recovery guarantees as tunnels.
final class NetworkProfileRepository {
    private let store: RecoverableJSONStore<[NetworkProfile]>

    var recoveryWarning: String? { store.recoveryWarning }

    init(file: URL = AppPaths.userMetadataDir.appendingPathComponent("networkProfiles.json")) {
        store = RecoverableJSONStore(file: file, emptyValue: [])
    }

    func load() throws -> [NetworkProfile] {
        try store.load()
    }

    func save(_ profiles: [NetworkProfile]) throws {
        try store.save(profiles)
    }
}
