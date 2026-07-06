import Foundation

struct WireGuardArtifactStatus: Equatable, Identifiable {
    let name: String
    let version: String
    let sourceURL: String
    let revision: String
    let architectures: [String]
    let expectedSHA256: String
    let actualSHA256: String?
    let isValid: Bool

    var id: String { name }
}

struct WireGuardRuntimeStatus: Equatable {
    enum Location: String {
        case bundled = "Bundled"
        case installed = "Installed"
    }

    let location: Location
    let source: String
    let generatedAt: Date?
    let verifiedAt: Date
    let artifacts: [WireGuardArtifactStatus]
    let errorMessage: String?

    var isValid: Bool {
        errorMessage == nil && artifacts.count == 3 && artifacts.allSatisfy(\.isValid)
    }

    var architectureSummary: String {
        Array(Set(artifacts.flatMap(\.architectures))).sorted().joined(separator: " / ")
    }

    var versionSummary: String {
        artifacts.map { "\($0.name) \($0.version)" }.joined(separator: ", ")
    }
}
