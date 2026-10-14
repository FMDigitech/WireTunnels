import Combine
import Foundation

@MainActor
final class TunnelConfigLoadingState: ObservableObject {
    @Published private(set) var contents: String?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    var canEdit: Bool { !isLoading && contents != nil && error == nil }

    func load(
        configURL: URL,
        managedTunnelID: UUID?,
        readManagedConfig: (UUID) async throws -> Data
    ) async {
        isLoading = true
        contents = nil
        error = nil
        defer { isLoading = false }
        do {
            let data: Data
            if let managedTunnelID {
                data = try await readManagedConfig(managedTunnelID)
            } else {
                data = try Data(contentsOf: configURL)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            contents = text
        } catch {
            self.error = error.localizedDescription
        }
    }
}
