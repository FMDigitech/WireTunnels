import Foundation

struct WireGuardManifest: Codable, Equatable {
    struct Patch: Codable, Equatable {
        let name: String
        let sha256: String
    }

    struct Artifact: Codable, Equatable {
        let name: String
        let version: String
        let sourceURL: String
        let revision: String
        let architectures: [String]
        let sha256: String
        let size: Int64
    }

    let schemaVersion: Int
    let generatedAt: String
    let source: String
    let patches: [Patch]
    let artifacts: [Artifact]
}

enum WireGuardManifestError: LocalizedError {
    case missingManifest
    case unsupportedSchema(Int)
    case invalidArtifactSet
    case unsafeArtifactName(String)
    case missingArtifact(String)
    case invalidArtifactType(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest: return "WireGuard runtime manifest is missing"
        case .unsupportedSchema(let version): return "Unsupported runtime manifest schema \(version)"
        case .invalidArtifactSet: return "Runtime manifest must contain exactly wg, wg-quick, and wireguard-go"
        case .unsafeArtifactName(let name): return "Unsafe runtime artifact name: \(name)"
        case .missingArtifact(let name): return "Runtime artifact is missing: \(name)"
        case .invalidArtifactType(let name): return "Runtime artifact is not a regular file: \(name)"
        }
    }
}

struct WireGuardManifestVerifier {
    static let expectedArtifactNames: Set<String> = ["wg", "wg-quick", "wireguard-go"]

    private let iso8601 = ISO8601DateFormatter()

    func loadManifest(from url: URL) throws -> WireGuardManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WireGuardManifestError.missingManifest
        }

        let manifest = try JSONDecoder().decode(
            WireGuardManifest.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
        guard manifest.schemaVersion == 1 else {
            throw WireGuardManifestError.unsupportedSchema(manifest.schemaVersion)
        }

        let names = manifest.artifacts.map(\.name)
        guard names.count == Self.expectedArtifactNames.count,
              Set(names).count == names.count,
              Set(names) == Self.expectedArtifactNames else {
            throw WireGuardManifestError.invalidArtifactSet
        }
        guard names.allSatisfy({ !$0.contains("/") && !$0.contains("..") }) else {
            throw WireGuardManifestError.unsafeArtifactName(
                names.first(where: { $0.contains("/") || $0.contains("..") }) ?? "unknown"
            )
        }
        return manifest
    }

    /// Reads the bundled tools' provenance for display. The manifest's hashes aren't checked:
    /// Xcode re-signs the Mach-O tools after it's written, and the helper verifies what it
    /// installs against its own anchors.
    func inspect(directory: URL, manifestURL: URL) -> WireGuardRuntimeStatus {
        do {
            let manifest = try loadManifest(from: manifestURL)
            let statuses = try manifest.artifacts.map { artifact in
                let url = directory.appendingPathComponent(artifact.name, isDirectory: false)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw WireGuardManifestError.invalidArtifactType(artifact.name)
                }
                return WireGuardArtifactStatus(
                    name: artifact.name,
                    version: artifact.version,
                    sourceURL: artifact.sourceURL,
                    revision: artifact.revision,
                    architectures: artifact.architectures
                )
            }

            return WireGuardRuntimeStatus(
                source: manifest.source,
                generatedAt: iso8601.date(from: manifest.generatedAt),
                artifacts: statuses,
                errorMessage: nil
            )
        } catch {
            return WireGuardRuntimeStatus(
                source: "Unknown",
                generatedAt: nil,
                artifacts: [],
                errorMessage: error.localizedDescription
            )
        }
    }
}
