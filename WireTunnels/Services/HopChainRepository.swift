import Foundation

/// Persists multi-hop pairings with the same recovery guarantees as tunnels.
final class HopChainRepository {
    private let store: RecoverableJSONStore<[HopChain]>

    var recoveryWarning: String? { store.recoveryWarning }

    init(file: URL = AppPaths.userMetadataDir.appendingPathComponent("hopChains.json")) {
        store = RecoverableJSONStore(file: file, emptyValue: [])
    }

    func load() throws -> [HopChain] {
        try store.load()
    }

    func save(_ chains: [HopChain]) throws {
        try store.save(chains)
    }
}
