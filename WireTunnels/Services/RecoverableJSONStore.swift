import Foundation
import Darwin

/// Keeps a validated previous snapshot and refuses to overwrite unreadable data.
final class RecoverableJSONStore<Value: Codable> {
    private let file: URL
    private let emptyValue: Value
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fm = FileManager.default
    private(set) var recoveryWarning: String?

    private var backup: URL { file.appendingPathExtension("backup") }

    init(file: URL, emptyValue: Value) {
        self.file = file
        self.emptyValue = emptyValue
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> Value {
        recoveryWarning = nil
        let primary: Data?
        do {
            primary = try read(file)
            if let primary, let value = try? decoder.decode(Value.self, from: primary) {
                return value
            }
        } catch {
            // A readable backup can still recover a primary with a read error.
            return try recoverBackup()
        }
        if let saved = try read(backup) {
            guard let value = try? decoder.decode(Value.self, from: saved) else {
                throw MetadataStorageError.unrecoverable
            }
            recoveryWarning = "Recovered \(file.lastPathComponent) from its backup. The original file will be preserved on the next save."
            return value
        }
        guard primary == nil else { throw MetadataStorageError.unrecoverable }
        return emptyValue
    }

    func save(_ value: Value) throws {
        let data = try encoder.encode(value)
        let primary = try read(file)
        let previous: Data
        if let primary {
            if (try? decoder.decode(Value.self, from: primary)) != nil {
                previous = primary
            } else {
                guard let saved = try read(backup), (try? decoder.decode(Value.self, from: saved)) != nil else {
                    throw MetadataStorageError.unrecoverable
                }
                previous = saved
                let preserved = file.deletingLastPathComponent()
                    .appendingPathComponent("\(file.lastPathComponent).corrupt-\(UUID().uuidString)")
                try write(primary, to: preserved)
            }
        } else if let saved = try read(backup) {
            guard (try? decoder.decode(Value.self, from: saved)) != nil else {
                throw MetadataStorageError.unrecoverable
            }
            previous = saved
        } else {
            previous = try encoder.encode(emptyValue)
        }
        // If creating the backup fails, the primary must remain untouched.
        try write(previous, to: backup)
        try write(data, to: file)
        recoveryWarning = nil
        if primary == nil {
            // A new store has no previous populated snapshot. Once the primary
            // is committed, make its first recovery snapshot useful as well.
            do { try write(data, to: backup) }
            catch {
                recoveryWarning = "Metadata was saved, but its recovery backup could not be updated: \(error.localizedDescription)"
            }
        }
    }

    private func recoverBackup() throws -> Value {
        guard let saved = try? read(backup),
              let value = try? decoder.decode(Value.self, from: saved) else {
            throw MetadataStorageError.unrecoverable
        }
        recoveryWarning = "Recovered \(file.lastPathComponent) from its backup. The original file will be preserved on the next save."
        return value
    }

    private func read(_ url: URL) throws -> Data? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw MetadataStorageError.unsafeFile
            }
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: url.path) { _ = try read(url) }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? fm.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        // Permissions and contents are complete before this atomic commit. There
        // must be no throwing step after a successful rename.
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum MetadataStorageError: LocalizedError {
    case unrecoverable
    case unsafeFile

    var errorDescription: String? {
        switch self {
        case .unrecoverable:
            return "Metadata could not be read and no valid backup is available. Existing files were left unchanged."
        case .unsafeFile:
            return "Metadata must be stored in a regular file. Existing files were left unchanged."
        }
    }
}
