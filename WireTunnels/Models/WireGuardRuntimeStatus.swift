import Foundation

struct WireGuardArtifactStatus: Equatable, Identifiable {
    let name: String
    let version: String
    let sourceURL: String
    let revision: String
    let architectures: [String]

    var id: String { name }
}

/// Provenance of the bundled tools, read from their manifest for display.
/// Whether the installed tools are genuine is up to the helper (`toolStatus`).
struct WireGuardRuntimeStatus: Equatable {
    let source: String
    let generatedAt: Date?
    let artifacts: [WireGuardArtifactStatus]
    let errorMessage: String?

    var architectureSummary: String {
        Array(Set(artifacts.flatMap(\.architectures))).sorted().joined(separator: " / ")
    }

    var versionSummary: String {
        artifacts.map { "\($0.name) \($0.version)" }.joined(separator: ", ")
    }
}
