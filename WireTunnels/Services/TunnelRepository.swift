import Foundation

final class TunnelRepository {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        createDirectoriesIfNeeded()
    }

    func load() -> [Tunnel] {
        guard FileManager.default.fileExists(atPath: AppPaths.metadataFile.path),
              let data = try? Data(contentsOf: AppPaths.metadataFile),
              let tunnels = try? decoder.decode([Tunnel].self, from: data) else {
            return []
        }
        return tunnels
    }

    func save(_ tunnels: [Tunnel]) {
        guard let data = try? encoder.encode(tunnels) else { return }
        try? data.write(to: AppPaths.metadataFile, options: .atomic)
    }

    private func createDirectoriesIfNeeded() {
        let dir = AppPaths.metadataFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.userConfigDir, withIntermediateDirectories: true)
    }
}
