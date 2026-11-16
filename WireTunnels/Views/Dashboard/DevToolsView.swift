import Darwin
import SwiftUI

/// What one look at the local end of a forward found. Looking opens one short connection through the
/// forward, so it only runs when the user asks.
private struct ForwardCheck: Equatable {
    enum Local: Equatable { case listening, closed, notApplicable }
    enum Remote: Equatable { case answers, noAnswer, notChecked }
    var local: Local
    var remote: Remote
    var at: Date
}

private enum PortProbe {
    /// Connects to 127.0.0.1:`port`. `listening` is whether something accepted. `held` is whether the
    /// connection stayed open: ssh accepts first and drops the connection when the far target refuses,
    /// so an immediate close means the remote service did not answer. A service that waits for the
    /// client to speak first looks the same as one that answers: the check cannot tell those apart.
    nonisolated static func probe(port: Int) -> (listening: Bool, held: Bool) {
        guard (1...65535).contains(port) else { return (false, false) }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return (false, false) }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 && errno != EINPROGRESS { return (false, false) }
        var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&writable, 1, 1000) > 0 else { return (false, false) }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
        guard failure == 0 else { return (false, false) }
        var readable = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&readable, 1, 700) > 0 else { return (true, true) }
        var byte: UInt8 = 0
        return (true, recv(descriptor, &byte, 1, MSG_PEEK) > 0)
    }

    /// Runs `ssh` once with the tunnel's own host, user and port, never asking for a password.
    nonisolated static func sshTest(_ tunnel: SSHTunnel) -> (ok: Bool, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-p", String(tunnel.port), "--",
                             tunnel.user.map { "\($0)@\(tunnel.host)" } ?? tunnel.host, "true"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (false, "ssh could not be started: \(error.localizedDescription)") }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 { return (true, "The host answered and your key was accepted.") }
        let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh exited with status \(process.terminationStatus)."
        return (false, last)
    }
}

private func describe(_ forward: SSHForward) -> String {
    switch forward.kind {
    case .local: return "localhost:\(forward.listenPort) → \(forward.targetHost):\(forward.targetPort)"
    case .remote: return "server:\(forward.listenPort) ← \(forward.targetHost):\(forward.targetPort)"
    case .dynamic: return "SOCKS5 on localhost:\(forward.listenPort)"
    }
}

/// Wake-on-LAN and SSH port forwards that reconnect by themselves. ssh runs as you with your own keys.
struct DevToolsView: View {
    @ObservedObject var manager: DevToolsManager
    @State private var editingWake: WakeTarget?
    @State private var editingSSH: SSHTunnel?
    @State private var checks: [UUID: ForwardCheck] = [:]
    @State private var checking: Set<UUID> = []
    @State private var selection: DevItem?

    /// One row of the list: an SSH tunnel or a Wake-on-LAN machine.
    private enum DevItem: Hashable {
        case ssh(UUID), wake(UUID)
    }

    private enum WakeStatus: Equatable {
        case sent, checking, awake(seconds: Int), noAnswer, failed
    }

    @State private var wakeStatus: [UUID: WakeStatus] = [:]
    @State private var wakeTasks: [UUID: Task<Void, Never>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Developer Tools").font(.title2.bold())
                Text("SSH port forwards that come back after a drop, and Wake-on-LAN. ssh runs as you with your own keys and agent; it never asks for a password.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            banner
            if let error = manager.errorMessage {
                Notice(tone: .bad, title: "Could not save", message: error)
            }
            MasterDetail(masterFraction: 0.42, masterMin: 330, detailMin: 360, inset: 0) {
                itemList
            } detail: {
                ScrollView { detailContent.padding(16) }
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingWake) { target in
            WakeTargetEditor(target: target, others: manager.data.wakeTargets.filter { $0.id != target.id }) { manager.saveWakeTarget($0) }
        }
        .sheet(item: $editingSSH) { tunnel in
            SSHTunnelEditor(tunnel: tunnel, manager: manager) { manager.saveSSHTunnel($0) }
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        let tunnels = manager.data.sshTunnels
        let states = tunnels.map { manager.state(of: $0.id) }
        let failed = states.filter { if case .failed = $0 { return true } else { return false } }.count
        let waiting = states.filter { if case .waiting = $0 { return true } else { return false } }.count
        let running = states.filter { $0 == .running }.count
        if tunnels.isEmpty && manager.data.wakeTargets.isEmpty {
            SummaryBanner(tone: .neutral, title: "Nothing set up", detail: "Add an SSH tunnel or a Wake-on-LAN machine below.")
        } else if failed > 0 {
            SummaryBanner(tone: .bad, title: "\(failed) SSH tunnel\(failed == 1 ? "" : "s") failed", detail: "See the reason on the tunnel below.")
        } else if waiting > 0 {
            SummaryBanner(tone: .warn, title: "\(waiting) SSH tunnel\(waiting == 1 ? " is" : "s are") reconnecting", detail: "ssh stopped and will start again by itself.")
        } else if running > 0 {
            SummaryBanner(tone: .good, title: "\(running) SSH tunnel\(running == 1 ? " is" : "s are") running",
                          detail: "Use Check on a tunnel to test its local port and the remote service.")
        } else {
            SummaryBanner(tone: .neutral, title: "No SSH tunnel is running", detail: "Turn one on with its switch.")
        }
    }

    // MARK: SSH

    private var itemList: some View {
        List(selection: $selection) {
            Section {
                if manager.data.sshTunnels.isEmpty {
                    Text("No SSH tunnels yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(manager.data.sshTunnels) { tunnel in sshRow(tunnel).tag(DevItem.ssh(tunnel.id)) }
            } header: {
                HStack {
                    Text("SSH tunnels (\(manager.data.sshTunnels.count))")
                    Spacer()
                    Button {
                        editingSSH = SSHTunnel(name: "", host: "", forwards: [SSHForward(listenPort: 8080, targetHost: "localhost", targetPort: 80)])
                    } label: { Label("Add", systemImage: "plus") }
                }
            }
            Section {
                if manager.data.wakeTargets.isEmpty {
                    Text("No machines yet. The packet is a broadcast, so the machine must be on the same network or reachable through a tunnel that carries broadcasts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(manager.data.wakeTargets) { target in wakeRow(target).tag(DevItem.wake(target.id)) }
            } header: {
                HStack {
                    Text("Wake-on-LAN (\(manager.data.wakeTargets.count))")
                    Spacer()
                    Button { editingWake = WakeTarget(name: "", macAddress: "") } label: { Label("Add", systemImage: "plus") }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func sshRow(_ tunnel: SSHTunnel) -> some View {
        let state = manager.state(of: tunnel.id)
        return HStack(spacing: 10) {
            Toggle("Run \(tunnel.name)", isOn: Binding(
                get: { state != .stopped && !isFailed(state) },
                set: { $0 ? manager.startSSH(tunnel.id) : manager.stopSSH(tunnel.id) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name).font(.headline).lineLimit(1)
                Text("\(tunnel.user.map { $0 + "@" } ?? "")\(tunnel.host):\(tunnel.port)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            processPill(state)
        }
        .padding(.vertical, 3)
    }

    private func wakeRow(_ target: WakeTarget) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.headline).lineLimit(1)
                Text(target.macAddress).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            wakePill(target)
            Button("Wake") { wake(target) }.controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    /// What is known about the last wake attempt, in words: sent is not the same as awake.
    private func wakePill(_ target: WakeTarget) -> StatusPill {
        switch wakeStatus[target.id] {
        case .sent?: return StatusPill(text: "Sent", tone: .info, showsIcon: false)
        case .checking?: return StatusPill(text: "Waiting", tone: .info, showsIcon: false)
        case .awake?: return StatusPill(text: "Answered", tone: .good)
        case .noAnswer?: return StatusPill(text: "No answer", tone: .warn)
        case .failed?: return StatusPill(text: "Not sent", tone: .bad)
        case nil: return StatusPill(text: "Not confirmed", tone: .neutral, showsIcon: false)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        let first: DevItem? = manager.data.sshTunnels.first.map { .ssh($0.id) } ?? manager.data.wakeTargets.first.map { .wake($0.id) }
        switch selection ?? first {
        case .ssh(let id)?:
            if let tunnel = manager.data.sshTunnels.first(where: { $0.id == id }) { sshCard(tunnel) }
        case .wake(let id)?:
            if let target = manager.data.wakeTargets.first(where: { $0.id == id }) { wakeCard(target) }
        case nil:
            EmptyPane(icon: "terminal", title: "Nothing selected", message: "Add an SSH tunnel or a Wake-on-LAN machine, then pick it in the list.")
        }
    }

    private func sshCard(_ tunnel: SSHTunnel) -> some View {
        let state = manager.state(of: tunnel.id)
        return Card(padding: 0, plain: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Toggle("Run \(tunnel.name)", isOn: Binding(
                        get: { state != .stopped && !isFailed(state) },
                        set: { $0 ? manager.startSSH(tunnel.id) : manager.stopSSH(tunnel.id) }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tunnel.name).font(.headline)
                        Text("\(tunnel.user.map { $0 + "@" } ?? "")\(tunnel.host):\(tunnel.port)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        ForEach(Array(tunnel.forwards.enumerated()), id: \.offset) { _, forward in
                            Text(describe(forward)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit") { editingSSH = tunnel }
                    Button(role: .destructive) { manager.deleteSSHTunnel(tunnel.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete \(tunnel.name)")
                }
                Divider()
                MetricGrid(minimum: 130) {
                    checkTile("ssh process", processPill(state), note: processNote(state))
                    checkTile("Local port", localPill(tunnel, state: state), note: localNote(tunnel))
                    checkTile("Remote service", remotePill(tunnel, state: state), note: remoteNote(tunnel))
                    VStack(alignment: .trailing, spacing: 4) {
                        Button(checking.contains(tunnel.id) ? "Checking…" : "Check") { check(tunnel) }
                            .disabled(state != .running || checking.contains(tunnel.id))
                            .help("Opens one short connection through the first forward and reports what happened.")
                        if let at = checks[tunnel.id]?.at {
                            Text("Checked \(Format.clock(at))").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func checkTile(_ title: String, _ pill: StatusPill, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            pill
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func processPill(_ state: SSHTunnelState) -> StatusPill {
        switch state {
        case .stopped: return StatusPill(text: "Stopped", tone: .neutral)
        case .connecting: return StatusPill(text: "Connecting…", tone: .neutral)
        case .running: return StatusPill(text: "Running", tone: .good)
        case .waiting: return StatusPill(text: "Reconnecting", tone: .warn)
        case .failed: return StatusPill(text: "Failed", tone: .bad)
        }
    }

    private func processNote(_ state: SSHTunnelState) -> String? {
        switch state {
        case .waiting(let date, let reason): return "At \(Format.clock(date)): \(reason)"
        case .failed(let reason): return reason
        default: return nil
        }
    }

    private func localPill(_ tunnel: SSHTunnel, state: SSHTunnelState) -> StatusPill {
        guard let result = checks[tunnel.id], state == .running else {
            return StatusPill(text: state == .running ? "Not checked" : "—", tone: .neutral, showsIcon: false)
        }
        switch result.local {
        case .listening: return StatusPill(text: "Listening", tone: .good)
        case .closed: return StatusPill(text: "Not listening", tone: .bad)
        case .notApplicable: return StatusPill(text: "On the server", tone: .neutral, showsIcon: false)
        }
    }

    private func localNote(_ tunnel: SSHTunnel) -> String? {
        guard let forward = tunnel.forwards.first(where: { $0.kind != .remote }) else { return nil }
        return "localhost:\(forward.listenPort)"
    }

    private func remotePill(_ tunnel: SSHTunnel, state: SSHTunnelState) -> StatusPill {
        guard let result = checks[tunnel.id], state == .running else {
            return StatusPill(text: state == .running ? "Not checked" : "—", tone: .neutral, showsIcon: false)
        }
        switch result.remote {
        case .answers: return StatusPill(text: "Accepted", tone: .good)
        case .noAnswer: return StatusPill(text: "No answer", tone: .bad)
        case .notChecked: return StatusPill(text: "Not checked", tone: .neutral, showsIcon: false)
        }
    }

    private func remoteNote(_ tunnel: SSHTunnel) -> String? {
        switch checks[tunnel.id]?.remote {
        case .answers?: return "The connection stayed open. A service that waits for you to speak first looks the same."
        case .noAnswer?: return "The forward accepted, then closed at once: the target did not answer."
        case .notChecked?: return tunnel.forwards.first?.kind == .local ? nil : "Only local forwards can be tried from this Mac."
        case nil: return nil
        }
    }

    private func isFailed(_ state: SSHTunnelState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func check(_ tunnel: SSHTunnel) {
        checking.insert(tunnel.id)
        Task {
            let first = tunnel.forwards.first { $0.kind != .remote }
            var result = ForwardCheck(local: .notApplicable, remote: .notChecked, at: Date())
            if let first {
                let probe = await Task.detached { PortProbe.probe(port: first.listenPort) }.value
                result.local = probe.listening ? .listening : .closed
                if first.kind == .local, probe.listening { result.remote = probe.held ? .answers : .noAnswer }
            }
            result.at = Date()
            checks[tunnel.id] = result
            checking.remove(tunnel.id)
        }
    }

    // MARK: Wake-on-LAN

    private func wakeCard(_ target: WakeTarget) -> some View {
        Card(padding: 0, plain: true) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.name).font(.headline)
                    Text("\(target.macAddress) via \(target.broadcastAddress)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let address = target.checkAddress, !address.isEmpty {
                        Text("Checked at \(address)").font(.caption).foregroundStyle(.secondary)
                    }
                    wakeLine(target)
                }
                Spacer()
                Button("Wake") { wake(target) }
                Button("Edit") { editingWake = target }
                Button(role: .destructive) { manager.deleteWakeTarget(target.id) } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete \(target.name)")
            }
        }
    }

    @ViewBuilder
    private func wakeLine(_ target: WakeTarget) -> some View {
        switch wakeStatus[target.id] {
        case .sent?:
            Notice(tone: .info, title: "Packet sent", message: "The machine may take a minute to wake. Sent is not the same as awake; add an address to check to see when it answers.")
        case .checking?:
            Notice(tone: .info, title: "Packet sent · waiting for an answer", message: "Pinging \(target.checkAddress ?? "") every few seconds, for up to a minute.")
        case .awake(let seconds)?:
            Notice(tone: .good, title: "Answered after \(seconds) s", message: "\(target.checkAddress ?? "The address") replied to ping.")
        case .noAnswer?:
            Notice(tone: .warn, title: "Packet sent · no answer after a minute",
                   message: "It may be off, on another network, or not answering ping. The packet was sent; that is all that is known.")
        case .failed?:
            Notice(tone: .bad, title: "The packet could not be sent", message: "Check the MAC and broadcast address.")
        case nil:
            EmptyView()
        }
    }

    private func wake(_ target: WakeTarget) {
        wakeTasks[target.id]?.cancel()
        manager.wake(target)
        guard manager.lastWake?.id == target.id, manager.lastWake?.succeeded == true else {
            wakeStatus[target.id] = .failed
            return
        }
        guard let address = target.checkAddress, SSHTunnelCommand.isValidHost(address) else {
            wakeStatus[target.id] = .sent
            return
        }
        wakeStatus[target.id] = .checking
        wakeTasks[target.id] = Task {
            let start = Date()
            while !Task.isCancelled, Date().timeIntervalSince(start) < 60 {
                try? await Task.sleep(for: .seconds(4))
                let replies = await Task.detached { PingService.measureLatency(host: address, count: 1, timeoutSeconds: 2) }.value
                if !replies.isEmpty {
                    wakeStatus[target.id] = .awake(seconds: Int(Date().timeIntervalSince(start)))
                    return
                }
            }
            if !Task.isCancelled { wakeStatus[target.id] = .noAnswer }
        }
    }
}

// MARK: - New / edit Wake-on-LAN machine

private struct WakeTargetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WakeTarget
    @State private var check: String
    @State private var testResult: (ok: Bool, text: String)?
    let isNew: Bool
    let others: [WakeTarget]
    let onSave: (WakeTarget) -> Void

    init(target: WakeTarget, others: [WakeTarget], onSave: @escaping (WakeTarget) -> Void) {
        _draft = State(initialValue: target)
        _check = State(initialValue: target.checkAddress ?? "")
        isNew = target.name.isEmpty && target.macAddress.isEmpty
        self.others = others
        self.onSave = onSave
    }

    private var macIsValid: Bool { MagicPacket.parseMAC(draft.macAddress) != nil }
    private var checkTrimmed: String { check.trimmingCharacters(in: .whitespaces) }
    private var checkIsValid: Bool { checkTrimmed.isEmpty || SSHTunnelCommand.isValidHost(checkTrimmed) }
    private var nameIsSet: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canSave: Bool { nameIsSet && macIsValid && MagicPacket.isIPv4(draft.broadcastAddress) && checkIsValid }

    private var duplicate: WakeTarget? {
        guard let mac = MagicPacket.normalizedMAC(draft.macAddress) else { return nil }
        return others.first { MagicPacket.normalizedMAC($0.macAddress) == mac }
    }

    /// A directed broadcast should share its first three numbers with the machine's own address; a /24 is assumed.
    private var broadcastLooksWrong: Bool {
        guard MagicPacket.isIPv4(checkTrimmed), MagicPacket.isIPv4(draft.broadcastAddress),
              draft.broadcastAddress != "255.255.255.255" else { return false }
        return checkTrimmed.split(separator: ".").prefix(3) != draft.broadcastAddress.split(separator: ".").prefix(3)
    }

    private var candidate: WakeTarget {
        var saved = draft
        saved.name = draft.name.trimmingCharacters(in: .whitespaces)
        saved.macAddress = MagicPacket.normalizedMAC(draft.macAddress) ?? draft.macAddress
        saved.checkAddress = checkTrimmed.isEmpty ? nil : checkTrimmed
        return saved
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(isNew ? "Add Wake-on-LAN Machine" : "Edit Wake-on-LAN Machine").font(.headline)
                    TextField("Name", text: $draft.name)
                    TextField("MAC address (aa:bb:cc:dd:ee:ff)", text: $draft.macAddress)
                    if macIsValid, let mac = MagicPacket.normalizedMAC(draft.macAddress), mac != draft.macAddress.lowercased() {
                        Text("Saved as \(mac)").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Broadcast address", text: $draft.broadcastAddress)
                    TextField("Address to check (optional)", text: $check)
                    Text("A host name or IP that answers ping once the machine is up. Without it the app can only say the packet was sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let duplicate {
                    Section { Notice(tone: .warn, title: "Same MAC as “\(duplicate.name)”", message: "Two entries will wake the same machine.") }
                }
                if broadcastLooksWrong {
                    Section {
                        Notice(tone: .warn, title: "The broadcast address may not match",
                               message: "\(draft.broadcastAddress) does not look like it belongs to the network of \(checkTrimmed). The packet only reaches machines on the broadcast address's network.")
                    }
                }
                Section("Validation") {
                    Checklist(items: [
                        (nameIsSet, "Name is set"),
                        (macIsValid, "MAC is six pairs of hex digits, separated by colons or dashes"),
                        (MagicPacket.isIPv4(draft.broadcastAddress), "Broadcast is an IPv4 address such as 192.168.1.255"),
                        (checkIsValid, "Address to check is a valid host name or IP, or empty"),
                    ])
                }
                Section("Test") {
                    HStack {
                        Button("Send Test Packet") {
                            let sent = MagicPacket.send(to: candidate)
                            testResult = sent ? (true, "The packet was sent. This is not the same as the machine being awake.")
                                              : (false, "The packet could not be sent.")
                        }
                        .disabled(!(macIsValid && MagicPacket.isIPv4(draft.broadcastAddress)))
                        Spacer()
                    }
                    Text("This really sends a Wake-on-LAN packet to the machine.").font(.caption).foregroundStyle(.secondary)
                    if let testResult {
                        Notice(tone: testResult.ok ? .info : .bad, title: testResult.ok ? "Packet sent" : "Not sent", message: testResult.text)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(candidate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding()
        }
        .sheetFrame(width: 500, height: 660)
    }
}

// MARK: - New / edit SSH tunnel

private struct SSHTunnelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SSHTunnel
    @State private var user: String
    @State private var forwards: String
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @ObservedObject var manager: DevToolsManager
    let isNew: Bool
    let onSave: (SSHTunnel) -> Void

    init(tunnel: SSHTunnel, manager: DevToolsManager, onSave: @escaping (SSHTunnel) -> Void) {
        _draft = State(initialValue: tunnel)
        _user = State(initialValue: tunnel.user ?? "")
        _forwards = State(initialValue: tunnel.forwards.map(\.text).joined(separator: "\n"))
        self.manager = manager
        isNew = tunnel.name.isEmpty && tunnel.host.isEmpty
        self.onSave = onSave
    }

    /// One forward per line (see `SSHForward.text`); nil when a line does not parse.
    private var parsedForwards: [SSHForward]? {
        var result: [SSHForward] = []
        for line in forwards.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            guard let forward = SSHForward.parse(line) else { return nil }
            result.append(forward)
        }
        return result
    }

    private var candidate: SSHTunnel? {
        guard let parsed = parsedForwards else { return nil }
        var tunnel = draft
        tunnel.name = draft.name.trimmingCharacters(in: .whitespaces)
        tunnel.host = draft.host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        tunnel.user = trimmedUser.isEmpty ? nil : trimmedUser
        tunnel.forwards = parsed
        return tunnel
    }

    private var problem: String? {
        guard let candidate else { return "Write each forward as 8080:host:80, R:9000:host:3000 or D:1080." }
        return SSHTunnelCommand.problem(with: candidate)
    }

    private var checklist: [(ok: Bool, text: String)] {
        let host = draft.host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        return [
            (!draft.name.trimmingCharacters(in: .whitespaces).isEmpty, "Name is set"),
            (SSHTunnelCommand.isValidHost(host), "Host is a name or address without spaces or a leading dash"),
            (trimmedUser.isEmpty || SSHTunnelCommand.isValidUser(trimmedUser), "User is empty or has only safe characters"),
            (SSHTunnelCommand.isValidPort(draft.port), "SSH port is between 1 and 65535"),
            (parsedForwards?.isEmpty == false, "At least one forward, each written as 8080:host:80, R:9000:host:3000 or D:1080"),
            (problem == nil, "Forward ports are valid and none is used twice"),
        ]
    }

    /// A local listening port another running tunnel of ours already holds.
    private var busyPort: (port: Int, owner: String)? {
        guard let candidate else { return nil }
        for other in manager.data.sshTunnels where other.id != draft.id {
            let state = manager.state(of: other.id)
            guard state == .running || state == .connecting else { continue }
            for mine in candidate.forwards where mine.kind != .remote {
                if other.forwards.contains(where: { $0.kind != .remote && $0.listenPort == mine.listenPort }) {
                    return (mine.listenPort, other.name)
                }
            }
        }
        return nil
    }

    private var commandPreview: String? {
        guard let candidate, let arguments = SSHTunnelCommand.arguments(for: candidate) else { return nil }
        return "ssh " + arguments.joined(separator: " ")
    }

    private var canTest: Bool {
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        return !testing && SSHTunnelCommand.isValidHost(draft.host.trimmingCharacters(in: .whitespaces))
            && SSHTunnelCommand.isValidPort(draft.port) && (trimmedUser.isEmpty || SSHTunnelCommand.isValidUser(trimmedUser))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(isNew ? "New SSH Tunnel" : "Edit SSH Tunnel").font(.headline)
                    Text("Keep a port forward alive over SSH. ssh runs as you with your own keys; it never asks for a password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Configuration") {
                    TextField("Name", text: $draft.name)
                    TextField("Host", text: $draft.host)
                    TextField("User (optional)", text: $user)
                    TextField("SSH port", value: $draft.port, format: .number.grouping(.never))
                    Text("Forwards, one per line").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $forwards).frame(height: 76).font(.body.monospaced())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("8080:host:80 · Local: port 8080 on this Mac reaches host:80 as seen from the server")
                        Text("R:9000:host:3000 · Remote: port 9000 on the server reaches host:3000 as seen from this Mac")
                        Text("D:1080 · SOCKS5: a proxy on port 1080 that sends traffic out through the server")
                    }
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Toggle("Reconnect when the connection drops", isOn: $draft.reconnects)
                    Text("Restarts ssh after 2, 4, 8… up to 60 seconds.").font(.caption).foregroundStyle(.secondary)
                }
                if let busy = busyPort {
                    Section {
                        Notice(tone: .warn, title: "Port \(busy.port) is already in use",
                               message: "“\(busy.owner)” is running and listens on it. ssh would fail to start this forward.")
                    }
                }
                Section("Validation") { Checklist(items: checklist) }
                Section("What this tunnel will do") {
                    if let candidate, problem == nil {
                        ForEach(Array(candidate.forwards.enumerated()), id: \.offset) { _, forward in
                            Text(describe(forward)).font(.callout.monospaced())
                        }
                    } else {
                        Text("Fix the items above to see the preview.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Forwards listen on 127.0.0.1 only. ssh never asks for a password, and fails with an error if a port is busy instead of looking up but forwarding nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let commandPreview {
                        Text(commandPreview).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Section("Connection test") {
                    HStack {
                        Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(!canTest)
                        Spacer()
                    }
                    Text("Valid syntax is not a working connection. This runs ssh once to check that the host answers and your key is accepted. It opens no forward and saves nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let testResult {
                        Notice(tone: testResult.ok ? .good : .bad, title: testResult.ok ? "Connected" : "Could not connect", message: testResult.text)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Tunnel") {
                    if let candidate { onSave(candidate) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
            .padding()
        }
        .sheetFrame(width: 560, height: 800)
    }

    private func test() {
        guard let candidate else { return }
        testing = true
        testResult = nil
        Task {
            let result = await Task.detached { PortProbe.sshTest(candidate) }.value
            testResult = (result.ok, result.message)
            testing = false
        }
    }
}
