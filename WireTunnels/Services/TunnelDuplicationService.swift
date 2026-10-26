import Foundation

final class TunnelDuplicationService {
    private let configStorage: ConfigStorageService
    private let parser = WireGuardConfigParser()

    init(configStorage: ConfigStorageService) {
        self.configStorage = configStorage
    }

    func duplicate(
        _ source: Tunnel,
        existingTunnels: [Tunnel],
        reservedConfigNames: [String] = []
    ) throws -> Tunnel {
        guard source.scope == .personal else { throw TunnelDuplicationError.personalTunnelsOnly }
        let contents = try configStorage.readConfig(at: URL(fileURLWithPath: source.configPath))
        let parsed = parser.parse(string: contents)
        guard parsed.isValid else { throw TunnelDuplicationError.invalidConfiguration(parsed.validationErrors) }

        let existingNames = Set(existingTunnels.map { $0.name.lowercased() })
        let existingFiles = Set((existingTunnels.flatMap { tunnel in
            [tunnel.configPath, tunnel.runtimeConfigPath].compactMap { $0 }.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased()
            }
        } + reservedConfigNames.map { $0.lowercased() }))
        let base = ConfigStorageService.displayName(for: source.name)
        var number = 1
        let name: String
        let savedURL: URL
        while true {
            let suffix = number == 1 ? "_copy" : "_copy_\(number)"
            let candidate = String(base.prefix(50 - suffix.count)) + suffix
            number += 1
            guard !existingNames.contains(candidate.lowercased()),
                  !existingFiles.contains(ConfigStorageService.fileBaseName(for: candidate).lowercased()) else { continue }
            do {
                savedURL = try configStorage.saveConfig(name: candidate, content: contents)
                name = candidate
                break
            } catch ConfigStorageError.alreadyExists {
                continue
            }
        }

        var copy = Tunnel(name: name, configPath: savedURL.path)
        copy.address = parsed.address
        copy.allowedIPs = parsed.allowedIPs
        copy.dns = parsed.dns
        copy.endpoint = parsed.endpoint
        copy.publicKey = parsed.peerPublicKey
        copy.localPublicKey = parsed.privateKey.flatMap { WireGuardKey.publicKey(fromPrivateKey: $0) }
        copy.killSwitchEnabled = source.killSwitchEnabled
        copy.ipFamilyLeakWarningAcknowledged = source.ipFamilyLeakWarningAcknowledged
        copy.excludedRoutes = source.excludedRoutes
        copy.splitDNSDomains = source.splitDNSDomains
        copy.speedTestURL = source.speedTestURL
        copy.autoConnectRule = source.autoConnectRule
        copy.autoConnectRule.connect.enabled = false
        copy.autoConnectRule.disconnect.enabled = false
        return copy
    }
}

enum TunnelDuplicationError: LocalizedError {
    case personalTunnelsOnly
    case tunnelNotFound
    case invalidConfiguration([ConfigValidationError])

    var errorDescription: String? {
        switch self {
        case .personalTunnelsOnly: return "Only personal tunnels can be duplicated."
        case .tunnelNotFound: return "The tunnel no longer exists."
        case .invalidConfiguration(let errors): return errors.map(\.message).joined(separator: "\n")
        }
    }
}
