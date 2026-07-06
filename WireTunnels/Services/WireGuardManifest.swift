import CryptoKit
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
    case invalidArtifactSize(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest: return "WireGuard runtime manifest is missing"
        case .unsupportedSchema(let version): return "Unsupported runtime manifest schema \(version)"
        case .invalidArtifactSet: return "Runtime manifest must contain exactly wg, wg-quick, and wireguard-go"
        case .unsafeArtifactName(let name): return "Unsafe runtime artifact name: \(name)"
        case .missingArtifact(let name): return "Runtime artifact is missing: \(name)"
        case .invalidArtifactType(let name): return "Runtime artifact is not a regular file: \(name)"
        case .invalidArtifactSize(let name): return "Runtime artifact size does not match the manifest: \(name)"
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

    func inspect(
        directory: URL,
        manifestURL: URL,
        location: WireGuardRuntimeStatus.Location
    ) -> WireGuardRuntimeStatus {
        let verifiedAt: Date
        if location == .installed,
           let values = try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let modificationDate = values.contentModificationDate {
            verifiedAt = modificationDate
        } else {
            verifiedAt = Date()
        }

        do {
            let manifest = try loadManifest(from: manifestURL)
            let statuses = try manifest.artifacts.map { artifact in
                let url = directory.appendingPathComponent(artifact.name, isDirectory: false)
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw WireGuardManifestError.invalidArtifactType(artifact.name)
                }
                // Bundled Mach-O binaries are re-signed by Xcode after the build phase
                // writes the manifest, changing their size and hash. Bundle integrity is
                // already guaranteed by the macOS app signature verified by Gatekeeper.
                if location != .bundled {
                    guard Int64(values.fileSize ?? -1) == artifact.size else {
                        throw WireGuardManifestError.invalidArtifactSize(artifact.name)
                    }
                }

                let actualHash = try sha256(of: url)
                // For bundled artifacts, use the actual post-signing hash as the reference
                // so bundledBinariesMatchInstalled() can compare against the installed manifest.
                let referenceHash = location == .bundled ? actualHash : artifact.sha256
                return WireGuardArtifactStatus(
                    name: artifact.name,
                    version: artifact.version,
                    sourceURL: artifact.sourceURL,
                    revision: artifact.revision,
                    architectures: artifact.architectures,
                    expectedSHA256: referenceHash,
                    actualSHA256: actualHash,
                    isValid: actualHash.caseInsensitiveCompare(referenceHash) == .orderedSame
                )
            }

            return WireGuardRuntimeStatus(
                location: location,
                source: manifest.source,
                generatedAt: iso8601.date(from: manifest.generatedAt),
                verifiedAt: verifiedAt,
                artifacts: statuses,
                errorMessage: nil
            )
        } catch {
            return WireGuardRuntimeStatus(
                location: location,
                source: "Unknown",
                generatedAt: nil,
                verifiedAt: verifiedAt,
                artifacts: [],
                errorMessage: error.localizedDescription
            )
        }
    }

    func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
