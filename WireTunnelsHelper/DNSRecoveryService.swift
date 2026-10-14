import Darwin
import Foundation
import SystemConfiguration

struct DNSSettings: Codable, Equatable {
    var dns: [String]
    var search: [String]
}

enum DNSField: String, Codable { case dns, search }

struct DNSOwnerIdentity: Codable, Equatable {
    let token: String
    let alias: String
    let interface: String
    let device: UInt64
    let inode: UInt64
}

protocol DNSRecoveryNetwork {
    func serviceID(named name: String) throws -> String
    func serviceName(for id: String) throws -> String?
    func isAlive(_ owner: DNSOwnerIdentity) -> Bool
    func read(service: String, field: DNSField) throws -> [String]
    func write(service: String, field: DNSField, values: [String]) throws
}

enum DNSRecoveryError: Error, LocalizedError {
    case invalidInput, unsafeState, invalidJournal, unavailableService, staleOwner, networkOperation, journalIO
    var errorDescription: String? {
        switch self {
        case .invalidInput: return "Invalid DNS recovery arguments"
        case .unsafeState: return "DNS recovery state has unsafe ownership, permissions or file type"
        case .invalidJournal: return "DNS recovery journal is invalid"
        case .unavailableService: return "The network service is unavailable for DNS recovery"
        case .staleOwner: return "The DNS owner no longer matches its tunnel interface"
        case .networkOperation: return "Unable to read or update network DNS settings"
        case .journalIO: return "Unable to persist DNS recovery state"
        }
    }
}

/// A shared baseline prevents a newer tunnel from restoring an older tunnel's
/// abandoned DNS. Pending setters are persisted before mutation, including
/// restoration, so a fresh process can finish after forced termination.
struct DNSRecoveryService {
    static let systemDirectory = URL(fileURLWithPath: "/Library/Application Support/WireTunnels/dns-state", isDirectory: true)
    let directory: URL
    let network: DNSRecoveryNetwork
    let expectedUID: uid_t

    private struct Owner: Codable {
        let identity: DNSOwnerIdentity
        let sequence: UInt64
        var released = false
    }
    private struct Claim: Codable {
        let token: String
        var settings: DNSSettings
    }
    private struct FieldState: Codable {
        var baseline: [String]
        var expected: [String]
        var pending: [String]?
        var overridden = false
        var finished = false
    }
    private struct ServiceState: Codable {
        let id: String
        var claims: [Claim]
        var dns: FieldState
        var search: FieldState
    }
    private struct State: Codable {
        var version = 1
        var nextSequence: UInt64 = 1
        var owners: [Owner] = []
        var services: [ServiceState] = []
    }

    func set(owner: DNSOwnerIdentity, service: String, settings: DNSSettings) throws {
        try Self.validate(owner: owner)
        try Self.validate(settings: settings)
        guard Self.safeText(service, limit: 1024), network.isAlive(owner) else { throw DNSRecoveryError.staleOwner }
        try transaction { descriptor, state in
            prune(&state)
            try save(state, directoryFD: descriptor)
            try reconcile(&state, directoryFD: descriptor)
            guard network.isAlive(owner) else { throw DNSRecoveryError.staleOwner }
            if let existing = state.owners.first(where: { $0.identity.token == owner.token }) {
                guard existing.identity == owner else { throw DNSRecoveryError.staleOwner }
                // A delayed route-monitor callback must not recreate released ownership.
                if existing.released { return }
            } else {
                guard state.owners.count < 256, state.nextSequence < UInt64.max else { throw DNSRecoveryError.invalidJournal }
                state.owners.append(Owner(identity: owner, sequence: state.nextSequence))
                state.nextSequence += 1
            }
            let id = try network.serviceID(named: service)
            guard Self.safeText(id, limit: 1024) else { throw DNSRecoveryError.invalidInput }
            var index = state.services.firstIndex(where: { $0.id == id })
            if index == nil {
                guard state.services.count < 512 else { throw DNSRecoveryError.invalidJournal }
                let dns = try network.read(service: service, field: .dns)
                let search = try network.read(service: service, field: .search)
                try Self.validate(settings: DNSSettings(dns: dns, search: search))
                state.services.append(ServiceState(id: id, claims: [], dns: FieldState(baseline: dns, expected: dns), search: FieldState(baseline: search, expected: search)))
                index = state.services.count - 1
            }
            let i = index!
            let newClaim = !state.services[i].claims.contains(where: { $0.token == owner.token })
            if newClaim {
                // A deliberate new connection may claim DNS after a manual override;
                // that manual value becomes the baseline for eventual disconnect.
                state.services[i].dns.overridden = false
                state.services[i].search.overridden = false
            }
            state.services[i].dns.finished = false
            state.services[i].search.finished = false
            state.services[i].claims.removeAll { $0.token == owner.token }
            state.services[i].claims.append(Claim(token: owner.token, settings: settings))
            try save(state, directoryFD: descriptor)
            try reconcile(&state, directoryFD: descriptor)
            collectOwners(&state)
        }
    }

    func release(token: String) throws {
        guard UUID(uuidString: token) != nil else { throw DNSRecoveryError.invalidInput }
        try transaction { descriptor, state in
            for i in state.owners.indices where state.owners[i].identity.token == token { state.owners[i].released = true }
            prune(&state)
            try save(state, directoryFD: descriptor)
            try reconcile(&state, directoryFD: descriptor)
            collectOwners(&state)
        }
    }

    func recover() throws {
        try transaction { descriptor, state in
            prune(&state)
            try save(state, directoryFD: descriptor)
            try reconcile(&state, directoryFD: descriptor)
            collectOwners(&state)
        }
    }

    private func prune(_ state: inout State) {
        for i in state.owners.indices where !network.isAlive(state.owners[i].identity) { state.owners[i].released = true }
        let active = Set(state.owners.filter { !$0.released }.map { $0.identity.token })
        for i in state.services.indices { state.services[i].claims.removeAll { !active.contains($0.token) } }
    }

    private func collectOwners(_ state: inout State) {
        let referenced = Set(state.services.flatMap { $0.claims.map(\.token) })
        state.owners.removeAll { !referenced.contains($0.identity.token) && (!network.isAlive($0.identity) || !$0.released) }
    }

    private func reconcile(_ state: inout State, directoryFD: Int32) throws {
        for i in state.services.indices {
            guard let name = try network.serviceName(for: state.services[i].id) else {
                // A deleted service cannot be modified; retain its journal in case
                // it returns. Never apply its baseline to a same-named replacement.
                continue
            }
            let claims = state.services[i].claims
            let latest = claims.max { lhs, rhs in
                let a = state.owners.first { $0.identity.token == lhs.token }!.sequence
                let b = state.owners.first { $0.identity.token == rhs.token }!.sequence
                return a < b
            }
            for field in [DNSField.dns, .search] {
                var value = field == .dns ? state.services[i].dns : state.services[i].search
                if value.finished && latest == nil { continue }
                let current = try network.read(service: name, field: field)
                try Self.validate(values: current, field: field)
                let target = latest.map { field == .dns ? $0.settings.dns : $0.settings.search } ?? value.baseline
                if current != value.expected && current != value.pending {
                    // Record an external override, rather than later treating a
                    // coincidentally matching old setting as ours again.
                    value.baseline = current
                    value.expected = current
                    value.pending = nil
                    value.overridden = true
                }
                if value.overridden || current == target {
                    value.expected = current
                    value.pending = nil
                    value.finished = latest == nil
                    put(value, field: field, index: i, state: &state)
                    try save(state, directoryFD: directoryFD)
                    continue
                }
                value.expected = current
                value.pending = target
                put(value, field: field, index: i, state: &state)
                try save(state, directoryFD: directoryFD)
                try network.write(service: name, field: field, values: target)
                guard try network.read(service: name, field: field) == target else { throw DNSRecoveryError.networkOperation }
                value.expected = target
                value.pending = nil
                value.finished = latest == nil
                put(value, field: field, index: i, state: &state)
                try save(state, directoryFD: directoryFD)
            }
        }
        state.services.removeAll { $0.claims.isEmpty && $0.dns.finished && $0.search.finished }
    }

    private func put(_ value: FieldState, field: DNSField, index: Int, state: inout State) {
        if field == .dns { state.services[index].dns = value }
        else { state.services[index].search = value }
    }

    private func transaction(_ operation: (Int32, inout State) throws -> Void) throws {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw DNSRecoveryError.journalIO }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw DNSRecoveryError.unsafeState }
        defer { close(directoryFD) }
        var attributes = stat()
        guard fstat(directoryFD, &attributes) == 0, attributes.st_uid == expectedUID,
              attributes.st_mode & 0o077 == 0, attributes.st_mode & S_IFMT == S_IFDIR else { throw DNSRecoveryError.unsafeState }
        let lockFD = openat(directoryFD, "lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw DNSRecoveryError.unsafeState }
        defer { close(lockFD) }
        try validateFile(lockFD)
        while flock(lockFD, LOCK_EX) != 0 { if errno != EINTR { throw DNSRecoveryError.journalIO } }
        defer { _ = flock(lockFD, LOCK_UN) }
        var state = try load(directoryFD: directoryFD)
        try operation(directoryFD, &state)
        try save(state, directoryFD: directoryFD)
    }

    private func validateFile(_ descriptor: Int32) throws {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_uid == expectedUID,
              attributes.st_mode & 0o077 == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_nlink == 1 else { throw DNSRecoveryError.unsafeState }
    }

    private func load(directoryFD: Int32) throws -> State {
        let descriptor = openat(directoryFD, "state.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return State() }
            throw DNSRecoveryError.unsafeState
        }
        defer { close(descriptor) }
        try validateFile(descriptor)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw DNSRecoveryError.journalIO }
            if count == 0 { break }
            data.append(bytes, count: count)
            guard data.count <= 1_048_576 else { throw DNSRecoveryError.invalidJournal }
        }
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { throw DNSRecoveryError.invalidJournal }
        try validate(state)
        return state
    }

    private func save(_ state: State, directoryFD: Int32) throws {
        try validate(state)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 1_048_576 else { throw DNSRecoveryError.invalidJournal }
        let temporary = ".state-" + UUID().uuidString
        let descriptor = openat(directoryFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DNSRecoveryError.journalIO }
        defer { close(descriptor); _ = unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DNSRecoveryError.journalIO }
                written += count
            }
        }
        guard fsync(descriptor) == 0, renameat(directoryFD, temporary, directoryFD, "state.json") == 0 else { throw DNSRecoveryError.journalIO }
        // The file is synced before rename. Sync the directory where supported.
        if fsync(directoryFD) != 0 && errno != EINVAL { throw DNSRecoveryError.journalIO }
    }

    private func validate(_ state: State) throws {
        guard state.version == 1, state.owners.count <= 256, state.services.count <= 512,
              state.nextSequence > 0, Set(state.owners.map { $0.identity.token }).count == state.owners.count,
              Set(state.services.map(\.id)).count == state.services.count else { throw DNSRecoveryError.invalidJournal }
        for owner in state.owners {
            try Self.validate(owner: owner.identity)
            guard owner.sequence > 0, owner.sequence < state.nextSequence else { throw DNSRecoveryError.invalidJournal }
        }
        let tokens = Set(state.owners.map { $0.identity.token })
        for service in state.services {
            guard Self.safeText(service.id, limit: 1024), service.claims.count <= 256,
                  Set(service.claims.map(\.token)).count == service.claims.count else { throw DNSRecoveryError.invalidJournal }
            for claim in service.claims {
                guard tokens.contains(claim.token) else { throw DNSRecoveryError.invalidJournal }
                try Self.validate(settings: claim.settings)
            }
            for field in [DNSField.dns, .search] {
                let value = field == .dns ? service.dns : service.search
                try Self.validate(values: value.baseline, field: field)
                try Self.validate(values: value.expected, field: field)
                if let pending = value.pending { try Self.validate(values: pending, field: field) }
            }
        }
    }

    static func validate(owner: DNSOwnerIdentity) throws {
        guard UUID(uuidString: owner.token) != nil,
              owner.alias.range(of: "^[a-zA-Z0-9_=+.-]{1,15}$", options: .regularExpression) != nil,
              owner.alias != ".", owner.alias != "..",
              owner.interface.range(of: "^utun[0-9]{1,10}$", options: .regularExpression) != nil,
              owner.inode > 0 else { throw DNSRecoveryError.invalidInput }
    }

    static func safeText(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= limit && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func validate(settings: DNSSettings) throws {
        try validate(values: settings.dns, field: .dns)
        try validate(values: settings.search, field: .search)
    }

    static func validate(values: [String], field: DNSField) throws {
        guard values.count <= 128 else { throw DNSRecoveryError.invalidInput }
        for value in values {
            guard safeText(value, limit: field == .dns ? 64 : 253),
                  !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { throw DNSRecoveryError.invalidInput }
            if field == .dns {
                var address4 = in_addr(), address6 = in6_addr()
                guard inet_pton(AF_INET, value, &address4) == 1 || inet_pton(AF_INET6, value, &address6) == 1 else { throw DNSRecoveryError.invalidInput }
            }
        }
    }
}

struct SystemDNSRecoveryNetwork: DNSRecoveryNetwork {
    private let runtimeDirectory: URL
    private let expectedUID: uid_t

    init(runtimeDirectory: URL = URL(fileURLWithPath: "/var/run/wireguard", isDirectory: true), expectedUID: uid_t = 0) {
        self.runtimeDirectory = runtimeDirectory
        self.expectedUID = expectedUID
    }

    private func services() throws -> [String: String] {
        guard let preferences = SCPreferencesCreate(nil, "WireTunnels DNS recovery" as CFString, nil),
              let current = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(current) as? [SCNetworkService] else { throw DNSRecoveryError.unavailableService }
        var result: [String: String] = [:]
        for service in services {
            if let name = SCNetworkServiceGetName(service), let id = SCNetworkServiceGetServiceID(service) { result[id as String] = name as String }
        }
        return result
    }

    func serviceID(named name: String) throws -> String {
        let matches = try services().filter { $0.value == name }
        guard matches.count == 1, let id = matches.first?.key else { throw DNSRecoveryError.unavailableService }
        return id
    }

    func serviceName(for id: String) throws -> String? { try services()[id] }

    func isAlive(_ owner: DNSOwnerIdentity) -> Bool {
        guard (try? DNSRecoveryService.validate(owner: owner)) != nil else { return false }
        let marker = runtimeDirectory.appendingPathComponent(owner.alias + ".name")
        var markerAttributes = stat()
        guard lstat(marker.path, &markerAttributes) == 0, markerAttributes.st_mode & S_IFMT == S_IFREG,
              markerAttributes.st_uid == expectedUID, markerAttributes.st_size > 0, markerAttributes.st_size <= 64,
              markerAttributes.st_mode & 0o022 == 0,
              let alias = try? String(contentsOf: marker, encoding: .utf8),
              alias.trimmingCharacters(in: .whitespacesAndNewlines) == owner.interface else { return false }
        let socketPath = runtimeDirectory.appendingPathComponent(owner.interface + ".sock").path
        func matchesSocketGeneration() -> Bool {
            var attributes = stat()
            return lstat(socketPath, &attributes) == 0 && attributes.st_mode & S_IFMT == S_IFSOCK &&
                attributes.st_uid == expectedUID && UInt64(attributes.st_ino) == owner.inode &&
                UInt64(UInt32(bitPattern: attributes.st_dev)) == owner.device
        }
        guard matchesSocketGeneration() else { return false }
        // wireguard-go can leave its pathname behind when killed. Connect to
        // the verified UAPI listener without sending any configuration data.
        guard listenerPresent(at: socketPath) else { return false }
        // The pathname may have been replaced while connect was in progress.
        return matchesSocketGeneration()
    }

    private func listenerPresent(at path: String) -> Bool {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { target in
                for index in bytes.indices { target[index] = bytes[index] }
            }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        // Resource exhaustion does not prove that a known live owner died.
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { return true }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        let failure = errno
        if failure == ECONNREFUSED || failure == ENOENT || failure == ENOTSOCK { return false }
        guard failure == EINPROGRESS || failure == EALREADY || failure == EINTR else { return true }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            // Congestion or an interrupted probe preserves ownership for retry.
            guard remaining > 0 else { return true }
            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&event, 1, Int32(min(100, ceil(remaining * 1000))))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return true }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return true }
            return error != ECONNREFUSED && error != ENOENT && error != ENOTSOCK
        }
    }

    func read(service: String, field: DNSField) throws -> [String] {
        let operation = field == .dns ? "-getdnsservers" : "-getsearchdomains"
        let output = try command([operation, service]).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("There aren't any ") { return [] }
        guard !output.isEmpty else { throw DNSRecoveryError.networkOperation }
        let values = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        try DNSRecoveryService.validate(values: values, field: field)
        return values
    }

    func write(service: String, field: DNSField, values: [String]) throws {
        _ = try command([field == .dns ? "-setdnsservers" : "-setsearchdomains", service] + (values.isEmpty ? ["Empty"] : values))
    }

    private func command(_ arguments: [String]) throws -> String {
        // Inherit the CLI's process group. Foundation Process creates a new
        // group, which could leave a setter alive after the helper kills setup.
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw DNSRecoveryError.networkOperation }
        defer { close(descriptors[0]) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        let argv = (["/usr/sbin/networksetup"] + arguments).map { strdup($0) }
        let environment: [String] = ["LC_ALL=C", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let env = environment.map { strdup($0) }
        defer { for argument in argv + env { free(argument) } }
        var argvPointers = argv + [nil]
        var envPointers = env + [nil]
        var pid: pid_t = 0
        let launched = argvPointers.withUnsafeMutableBufferPointer { argvBuffer in
            envPointers.withUnsafeMutableBufferPointer { envBuffer in
                posix_spawn(&pid, "/usr/sbin/networksetup", &actions, nil, argvBuffer.baseAddress!, envBuffer.baseAddress!)
            }
        }
        close(descriptors[1])
        guard launched == 0 else { throw DNSRecoveryError.networkOperation }
        var data = Data(), status: Int32 = 0
        var reaped = false
        defer {
            if !reaped { _ = kill(pid, SIGKILL); while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            while true {
                let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                data.append(buffer, count: count)
                guard data.count <= 65536 else { throw DNSRecoveryError.networkOperation }
            }
            if reaped { break }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; continue }
            guard waited >= 0 || errno == EINTR, ProcessInfo.processInfo.systemUptime < deadline else { throw DNSRecoveryError.networkOperation }
            usleep(10_000)
        }
        let output = String(decoding: data, as: UTF8.self)
        guard status == 0, !output.contains("Error") else { throw DNSRecoveryError.networkOperation }
        return output
    }
}

/// The helper's private CLI shares its signed executable with the daemon. It
/// accepts data arguments only and never executes commands from the journal.
enum DNSRecoveryCLI {
    static func run(arguments: [String]) throws {
        guard getuid() == 0, geteuid() == 0 else { throw DNSRecoveryError.unsafeState }
        let network = SystemDNSRecoveryNetwork()
        let service = DNSRecoveryService(directory: DNSRecoveryService.systemDirectory, network: network, expectedUID: 0)
        guard let operation = arguments.first else { throw DNSRecoveryError.invalidInput }
        switch operation {
        case "--dns-recover":
            guard arguments.count == 1 else { throw DNSRecoveryError.invalidInput }
            try service.recover()
        case "--dns-release":
            guard arguments.count == 2 else { throw DNSRecoveryError.invalidInput }
            try service.release(token: arguments[1])
        case "--dns-set":
            guard arguments.count >= 8 else { throw DNSRecoveryError.invalidInput }
            let identityParts = arguments[4].split(separator: ":", omittingEmptySubsequences: false)
            guard identityParts.count == 2, let device = UInt64(identityParts[0]), let inode = UInt64(identityParts[1]),
                  let dnsCount = Int(arguments[6]), dnsCount >= 0, dnsCount <= 128,
                  arguments.count > 7 + dnsCount,
                  let searchCount = Int(arguments[7 + dnsCount]), searchCount >= 0, searchCount <= 128,
                  arguments.count == 8 + dnsCount + searchCount else { throw DNSRecoveryError.invalidInput }
            let owner = DNSOwnerIdentity(token: arguments[1], alias: arguments[2], interface: arguments[3], device: device, inode: inode)
            let settings = DNSSettings(dns: Array(arguments[7..<(7 + dnsCount)]), search: Array(arguments[(8 + dnsCount)..<arguments.count]))
            try service.set(owner: owner, service: arguments[5], settings: settings)
        default: throw DNSRecoveryError.invalidInput
        }
    }
}
