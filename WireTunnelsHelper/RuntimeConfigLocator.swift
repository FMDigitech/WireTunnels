import Foundation

/// Resolves wg-quick's config aliases to their userspace utun interfaces.
/// A recycled utun must not inherit a stale alias from an earlier connection.
enum RuntimeConfigLocator {
    static func configPaths(
        in directory: URL,
        resolveConfig: (String) -> URL?
    ) throws -> [String: String] {
        let fm = FileManager.default
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
        var paths: [String: String] = [:]
        var ambiguous = Set<String>()
        for file in files where file.pathExtension == "name" {
            let configName = file.deletingPathExtension().lastPathComponent + ".conf"
            guard let config = resolveConfig(configName),
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let interface = contents.trimmingCharacters(in: .newlines)
            guard interface.hasPrefix("utun"),
                  !interface.dropFirst(4).isEmpty,
                  interface.dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            let socket = directory.appendingPathComponent(interface + ".sock")
            guard let socketAttributes = try? fm.attributesOfItem(atPath: socket.path),
                  socketAttributes[.type] as? FileAttributeType == .typeSocket,
                  let socketModified = socketAttributes[.modificationDate] as? Date,
                  abs(Int(socketModified.timeIntervalSince1970) - Int(modified.timeIntervalSince1970)) < 2 else { continue }
            if paths[interface] != nil { ambiguous.insert(interface) }
            paths[interface] = config.path
        }
        for interface in ambiguous { paths.removeValue(forKey: interface) }
        return paths
    }
}
