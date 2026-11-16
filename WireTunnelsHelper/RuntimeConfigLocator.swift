import Foundation

/// The two userspace implementations the helper can run a tunnel on. Each has its own quick
/// script, its own show tool, and its own runtime directory: awg-quick is patched to keep
/// its alias and socket files in /var/run/amneziawg (Scripts/awg-quick-socket-dir.patch),
/// apart from wg-quick's /var/run/wireguard.
enum RuntimeEngine: CaseIterable {
    case wireGuard
    case amneziaWG

    var quickTool: String { self == .wireGuard ? "wg-quick" : "awg-quick" }
    var showTool: String { self == .wireGuard ? "wg" : "awg" }
    var userspaceTool: String { self == .wireGuard ? "wireguard-go" : "amneziawg-go" }
    var runtimeDirectory: URL {
        URL(fileURLWithPath: self == .wireGuard ? "/var/run/wireguard" : "/var/run/amneziawg", isDirectory: true)
    }

    static var runtimeDirectories: [URL] { allCases.map(\.runtimeDirectory) }

    // Mirrors AmneziaWGKeys in WireTunnels/Services/WireGuardConfigParser.swift: Scripts/
    // test_amnezia_keys_in_sync.sh fails when the two lists differ. Lowercased for matching.
    static let amneziaInterfaceKeys: Set<String> = [
        "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4",
        "i1", "i2", "i3", "i4", "i5", "headerprotectionkey", "contentpaddingaddition",
        "rekeyaftertime", "rekeytimeout", "rejectaftertime", "keepalivetimeout",
        "maxhandshakeattempts", "randomtrailers", "disablecookies"
    ]
    static let amneziaPeerKeys: Set<String> = ["advancedsecurity"]

    /// The engine a config needs: AmneziaWG as soon as it uses a key only awg understands in
    /// the section awg reads it from, or when the app added the engine marker (see EngineMarker).
    /// The helper decides from the config it validated and
    /// staged itself, so an XPC client cannot pick which root tool runs.
    static func engine(forConfig text: String) -> RuntimeEngine {
        var section = ""
        var markerRequestsAmneziaWG = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if EngineMarker.isMarker(line) { markerRequestsAmneziaWG = true }
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            if section == "[interface]", amneziaInterfaceKeys.contains(key) { return .amneziaWG }
            if section == "[peer]", amneziaPeerKeys.contains(key) { return .amneziaWG }
        }
        // The app asks for awg on a config that has no awg-only key (the user chose the engine).
        return markerRequestsAmneziaWG ? .amneziaWG : .wireGuard
    }

    /// The engine whose runtime directory holds this alias's marker: a running tunnel stays
    /// on the engine that started it, whatever its config says now.
    static func engine(runningAlias alias: String) -> RuntimeEngine? {
        allCases.first {
            FileManager.default.fileExists(atPath: $0.runtimeDirectory.appendingPathComponent(alias + ".name").path)
        }
    }
}

/// `wg show all dump` and `awg show all dump` carry secrets the app must never receive:
/// shared tunnels' keys stay root-only. Both are reduced to the same shape the app reads: a
/// 5-field interface line (name, private key, public key, port, fwmark) and a 9-field peer line.
enum RuntimeStatusDump {
    /// wg: the interface line has 5 fields, the private key in the second; the peer line has
    /// 9, the preshared key in the third.
    static func redactedWireGuard(_ dump: String) -> String {
        dump.components(separatedBy: "\n").map { line in
            var fields = line.components(separatedBy: "\t")
            if fields.count == 5 { fields[1] = "(hidden)" }
            if fields.count == 9, fields[2] != "(none)" { fields[2] = "(hidden)" }
            return fields.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// awg: the peer line is the same 9 fields, but the interface line carries about thirty:
    /// the private key, the header protection key and every obfuscation parameter. Nothing
    /// of those is passed on. A line of any other shape is dropped rather than guessed at,
    /// so a future awg format cannot leak a field that was never reviewed.
    static func redactedAmnezia(_ dump: String) -> String {
        dump.components(separatedBy: "\n").compactMap { line -> String? in
            if line.isEmpty { return line }
            var fields = line.components(separatedBy: "\t")
            if fields.count == 9 {
                if fields[2] != "(none)" { fields[2] = "(hidden)" }
                return fields.joined(separator: "\t")
            }
            // name, private, public, port, ..., fwmark
            guard fields.count >= 6 else { return nil }
            return [fields[0], "(hidden)", fields[2], fields[3], fields[fields.count - 1]].joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

/// Resolves wg-quick's config aliases to their userspace utun interfaces.
/// A recycled utun must not inherit a stale alias from an earlier connection.
enum RuntimeConfigLocator {
    /// Without wg, a userspace socket prevents claiming that all tunnels are down.
    static func hasUserspaceSockets(in directory: URL) throws -> Bool {
        let fm = FileManager.default
        let files: [URL]
        do { files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { return false }
        return try files.contains { file in
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "sock", name.hasPrefix("utun"),
                  !name.dropFirst(4).isEmpty,
                  name.dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            let attributes = try fm.attributesOfItem(atPath: file.path)
            return attributes[.type] as? FileAttributeType == .typeSocket
        }
    }

    /// True when any engine's runtime directory holds a userspace socket.
    static func hasUserspaceSockets(inAny directories: [URL] = RuntimeEngine.runtimeDirectories) throws -> Bool {
        try directories.contains { try hasUserspaceSockets(in: $0) }
    }

    /// The running tunnels of every engine. Each engine keeps its alias and socket files in its
    /// own directory, so a directory is only ever matched with its own files; utun names are
    /// unique across them.
    static func configPaths(
        inAll directories: [URL] = RuntimeEngine.runtimeDirectories,
        resolveConfig: (String) -> URL?
    ) throws -> [String: String] {
        var merged: [String: String] = [:]
        for directory in directories {
            merged.merge(try configPaths(in: directory, resolveConfig: resolveConfig)) { current, _ in current }
        }
        return merged
    }

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
