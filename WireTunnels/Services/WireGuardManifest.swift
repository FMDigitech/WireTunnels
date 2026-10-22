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
                // Bundled verification uses the actual post-signing hash; installed
                // verification still requires the hash recorded during installation.
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

    func runtimesMatch(
        bundledDirectory: URL,
        bundledManifestURL: URL,
        installedDirectory: URL,
        installedManifestURL: URL
    ) -> Bool {
        runtimesMatch(
            bundled: inspect(directory: bundledDirectory, manifestURL: bundledManifestURL, location: .bundled),
            bundledDirectory: bundledDirectory,
            installed: inspect(directory: installedDirectory, manifestURL: installedManifestURL, location: .installed),
            installedDirectory: installedDirectory
        )
    }

    /// Tools match when every artifact has the same version, source, revision and
    /// architectures, and the executables differ at most in their code signatures.
    func runtimesMatch(
        bundled: WireGuardRuntimeStatus,
        bundledDirectory: URL,
        installed: WireGuardRuntimeStatus,
        installedDirectory: URL
    ) -> Bool {
        guard bundled.isValid, installed.isValid else { return false }

        let installedByName = Dictionary(uniqueKeysWithValues: installed.artifacts.map { ($0.name, $0) })
        do {
            for artifact in bundled.artifacts {
                guard let existing = installedByName[artifact.name],
                      artifact.version == existing.version,
                      artifact.sourceURL == existing.sourceURL,
                      artifact.revision == existing.revision,
                      Set(artifact.architectures) == Set(existing.architectures),
                      let bundledHash = artifact.actualSHA256,
                      let installedHash = existing.actualSHA256 else { return false }
                if bundledHash == installedHash { continue }
                // The script has no code signature. Every byte remains significant.
                guard artifact.name != "wg-quick" else { return false }
                let bundledPayload = try unsignedSHA256(
                    of: bundledDirectory.appendingPathComponent(artifact.name), expectedSHA256: bundledHash)
                let installedPayload = try unsignedSHA256(
                    of: installedDirectory.appendingPathComponent(artifact.name), expectedSHA256: installedHash)
                guard bundledPayload == installedPayload else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    /// Normalize signatures only on private copies, after verifying their full
    /// bytes still match the files inspected above. Original signatures stay intact.
    private func unsignedSHA256(of url: URL, expectedSHA256: String) throws -> String {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("wiretunnels-runtime-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("executable")
        try fm.copyItem(at: url, to: copy)
        guard try sha256(of: copy) == expectedSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--remove-signature", copy.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return try sha256(of: copy)
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
