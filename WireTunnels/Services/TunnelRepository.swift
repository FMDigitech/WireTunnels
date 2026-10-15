import Foundation

final class TunnelRepository {
    private let store: RecoverableJSONStore<[Tunnel]>

    var recoveryWarning: String? { store.recoveryWarning }

    init(file: URL = AppPaths.metadataFile) {
        store = RecoverableJSONStore(file: file, emptyValue: [])
    }

    func load() throws -> [Tunnel] {
        try store.load()
    }

    func save(_ tunnels: [Tunnel]) throws {
        try store.save(tunnels)
    }
}
