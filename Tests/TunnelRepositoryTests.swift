import Foundation

@main
struct TunnelRepositoryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tunnels.json")
        let repository = TunnelRepository(file: file)
        guard try repository.load().isEmpty else { fatalError("Fresh storage was not empty") }
        var first = Tunnel(name: "Office VPN", configPath: "/synthetic/office.conf")
        var second = Tunnel(name: "Backup VPN", configPath: "/synthetic/backup.conf")
        first.createdAt = Date(timeIntervalSince1970: 100)
        first.updatedAt = first.createdAt
        second.createdAt = first.createdAt
        second.updatedAt = first.createdAt
        try repository.save([first])
        let firstSnapshot = try Data(contentsOf: file)
        try Data("broken first save".utf8).write(to: file)
        guard try repository.load() == [first] else { fatalError("The first saved collection had no useful recovery snapshot") }
        try firstSnapshot.write(to: file)
        try repository.save([first, second])
        guard try repository.load() == [first, second] else { fatalError("Save did not persist tunnel metadata") }
        let corrupt = Data("{interrupted write".utf8)
        try corrupt.write(to: file)
        guard try repository.load() == [first], repository.recoveryWarning != nil else {
            fatalError("Corrupt metadata became an empty collection instead of recovering its backup")
        }
        try repository.save([first])
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
        guard preserved.count == 1, try Data(contentsOf: preserved[0]) == corrupt else { fatalError("Recovery discarded the damaged original") }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { fatalError("Metadata is not private") }
        let unreadable = root.appendingPathComponent("bad.json")
        try corrupt.write(to: unreadable)
        let damaged = TunnelRepository(file: unreadable)
        do {
            _ = try damaged.load()
            fatalError("Corrupt metadata without a backup loaded as an empty collection")
        } catch MetadataStorageError.unrecoverable { }
        do {
            try damaged.save([])
            fatalError("Saving an empty collection destroyed unrecoverable metadata")
        } catch MetadataStorageError.unrecoverable { }
        guard try Data(contentsOf: unreadable) == corrupt else { fatalError("Blocked save modified corrupt metadata") }
        let absent = root.appendingPathComponent("absent.json")
        try corrupt.write(to: absent.appendingPathExtension("backup"))
        do {
            _ = try TunnelRepository(file: absent).load()
            fatalError("Missing primary and corrupt backup loaded as an empty collection")
        } catch MetadataStorageError.unrecoverable { }
        // A failed write must leave both the current metadata and its backup intact.
        let stable = try Data(contentsOf: file)
        let backup = file.appendingPathExtension("backup")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        do {
            try repository.save([second])
            fatalError("Backup failure was hidden from the caller")
        } catch { }
        guard try Data(contentsOf: file) == stable else { fatalError("Backup failure replaced current metadata") }
        let chains = HopChainRepository(file: root.appendingPathComponent("hopChains.json"))
        var chain = HopChain(hopTunnelID: first.id, exitTunnelID: second.id)
        chain.createdAt = first.createdAt
        try chains.save([chain])
        guard try chains.load() == [chain] else { fatalError("Hop-chain metadata did not use protected persistence") }
        print("PASS: metadata recovers valid backups, preserves corrupt originals, blocks destructive saves, and reports write failures")
    }
}
