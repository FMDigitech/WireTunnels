import SwiftUI

/// What to do on a network: which DNS servers to use, which tunnels to turn on or off, which proxy and
/// which Shortcut to run. The first enabled profile that matches wins, so the order of the list matters:
/// drag rows or use Move up / Move down.
struct NetworkProfilesView: View {
    @ObservedObject var manager: NetworkProfileManager
    let tunnels: [Tunnel]
    @State private var editing: NetworkProfile?
    @State private var isNew = false
    @State private var selectedID: UUID?
    @Environment(\.masterIsCompact) private var compact

    private var selected: NetworkProfile? {
        manager.profiles.first { $0.id == selectedID } ?? manager.profiles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banner

            if let message = manager.dnsFlushMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let error = manager.errorMessage {
                Notice(tone: .bad, title: "A profile could not be applied", message: error)
            }

            if manager.profiles.isEmpty {
                EmptyPane(icon: "network", title: "No profiles yet",
                          message: "A profile sets DNS, a proxy, tunnels or a Shortcut when you join a network.")
            } else {
                MasterDetail(masterFraction: 0.42, masterMin: 340, detailMin: 360, inset: 0) {
                    List(selection: $selectedID) {
                        ForEach(Array(manager.profiles.enumerated()), id: \.element.id) { index, profile in
                            row(profile, index: index).tag(profile.id)
                        }
                        .onMove { source, destination in
                            var reordered = manager.profiles
                            reordered.move(fromOffsets: source, toOffset: destination)
                            Task { await manager.save(reordered) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                } detail: {
                    ScrollView {
                        if let profile = selected { detail(profile).padding(16) }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { profile in
            NetworkProfileEditor(profile: profile, isNew: isNew, currentSSID: manager.currentSSID, tunnels: tunnels, manager: manager) { saved, placeAtTop in
                var updated = manager.profiles
                if let index = updated.firstIndex(where: { $0.id == saved.id }) {
                    updated[index] = saved
                } else if placeAtTop {
                    updated.insert(saved, at: 0)
                } else {
                    updated.append(saved)
                }
                selectedID = saved.id
                Task { await manager.save(updated) }
            }
        }
    }

    // MARK: Header and banner

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Network Profiles").font(.title2.bold())
                Text("Pick DNS servers, a proxy, tunnels or a Shortcut when you join a network. A connected tunnel's own DNS always wins, and changing DNS needs an administrator account.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await manager.flushDNSCache() }
            } label: {
                Label(manager.isFlushingDNS ? "Flushing…" : "Flush DNS Cache", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(manager.isFlushingDNS)
            .help("Empties the system's DNS cache. It is also done by itself whenever a profile changes the DNS servers.")
            Button {
                isNew = true
                editing = NetworkProfile(name: "")
            } label: {
                Label("Add Profile", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        let network = manager.currentSSID.map { "Wi-Fi · \($0)" } ?? "this network"
        if let active = manager.profiles.first(where: { $0.id == manager.activeProfileID }) {
            SummaryBanner(tone: .good, title: "“\(active.name)” is the active profile",
                          detail: "Applied on \(network). \(manager.profiles.count) profile\(manager.profiles.count == 1 ? "" : "s"), the first enabled match wins.")
        } else if manager.profiles.isEmpty {
            SummaryBanner(tone: .neutral, title: "No profiles yet", detail: "Add one to change DNS, proxy, tunnels or a Shortcut per network.")
        } else {
            SummaryBanner(tone: .neutral, title: "No profile applies on \(network)",
                          detail: "Nothing is changed here. Profiles apply when an enabled one matches the network you are on.")
        }
    }

    // MARK: Status

    private enum Status {
        case active, inactive, disabled
        case shadowed(by: String)

        var label: String {
            switch self {
            case .active: return "Active"
            case .inactive: return "Inactive"
            case .disabled: return "Disabled"
            case .shadowed: return "Shadowed"
            }
        }
        var tone: StatusTone {
            switch self {
            case .active: return .good
            case .shadowed: return .warn
            default: return .neutral
            }
        }
        var note: String? {
            if case .shadowed(let name) = self { return "by \(name)" }
            return nil
        }
    }

    private func status(of profile: NetworkProfile) -> Status {
        if !profile.isEnabled { return .disabled }
        if manager.activeProfileID == profile.id { return .active }
        if let above = NetworkProfileResolver.shadowingProfile(of: profile, in: manager.profiles) { return .shadowed(by: above.name) }
        return .inactive
    }

    private func row(_ profile: NetworkProfile, index: Int) -> some View {
        let state = status(of: profile)
        return HStack(spacing: 10) {
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18)
            Toggle("Enabled", isOn: Binding(
                get: { profile.isEnabled },
                set: { enabled in
                    var updated = manager.profiles
                    if let i = updated.firstIndex(where: { $0.id == profile.id }) {
                        updated[i].isEnabled = enabled
                        Task { await manager.save(updated) }
                    }
                }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                FlowLayout(spacing: 6) {
                    Text(profile.name).font(.headline)
                    StatusPill(text: state.label, tone: state.tone)
                    if let note = state.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                Text(matchText(profile)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // The outcome summary is repeated in the detail pane, so a narrow list leaves it out.
            if !compact { Text(outcomeChips(profile)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Button("Edit") { isNew = false; editing = profile }
            Button(role: .destructive) {
                Task { await manager.save(manager.profiles.filter { $0.id != profile.id }) }
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete \(profile.name)")
        }
        .padding(.vertical, 4)
    }

    // MARK: Detail

    private func detail(_ profile: NetworkProfile) -> some View {
        let state = status(of: profile)
        let index = manager.profiles.firstIndex { $0.id == profile.id } ?? 0
        let active = manager.activeProfileID == profile.id
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(profile.name).font(.title3.weight(.semibold))
                        StatusPill(text: state.label, tone: state.tone)
                        Spacer()
                        Text("Priority \(index + 1) of \(manager.profiles.count)").font(.caption).foregroundStyle(.secondary)
                        Button("Move up") { move(profile, by: -1) }.disabled(index == 0)
                        Button("Move down") { move(profile, by: 1) }.disabled(index >= manager.profiles.count - 1)
                    }
                    switch state {
                    case .shadowed(let name):
                        Notice(tone: .warn, title: "It may never run",
                               message: "“\(name)” is above it and matches every network this profile matches. Move this one above it, or narrow the other.")
                    case .disabled:
                        Notice(tone: .info, title: "Disabled", message: "It is skipped when the app looks for a match.")
                    case .inactive:
                        Notice(tone: .info, title: "Not active", message: "It applies on \(matchText(profile).lowercased()); this Mac is on a different network.")
                    case .active:
                        EmptyView()
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        PaneSectionHeader(title: "What this profile applies")
                        Spacer()
                        Text(active ? "Result on this network" : "Applied when the profile becomes active").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(outcomes(profile, active: active), id: \.id) { outcome in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(outcome.kind).font(.callout.weight(.semibold)).frame(width: 80, alignment: .leading)
                            Text(outcome.setting).font(.callout)
                            Spacer()
                            if let result = outcome.result {
                                StatusPill(text: result.text, tone: result.tone)
                            }
                        }
                    }
                    if active, !profile.dnsServers.isEmpty, tunnels.contains(where: { $0.isActive && !WireGuardDNS.servers($0.dns).isEmpty }) {
                        Text("While a tunnel is connected, its own DNS takes precedence over this setting.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            dnsCheck(profile)
        }
    }

    /// An optional, on-demand look at the profile's DNS servers. Nothing is measured in the background.
    private func dnsCheck(_ profile: NetworkProfile) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                PaneSectionHeader(title: "DNS check", note: "Optional · sends one small DNS query to each server, only when you press the button")
                if profile.dnsServers.isEmpty {
                    Text("This profile leaves DNS unchanged, so there is nothing to check.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(manager.isTestingDNS ? "Testing…" : "Test DNS") { Task { await manager.testDNS(profile.dnsServers) } }
                            .disabled(manager.isTestingDNS)
                        Spacer()
                    }
                    let tested = profile.dnsServers.filter { manager.dnsTestResults[$0] != nil }
                    if tested.isEmpty {
                        Text("Not measured yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(tested, id: \.self) { server in
                        HStack {
                            Text(server).font(.callout.monospaced())
                            Spacer()
                            switch manager.dnsTestResults[server] {
                            case .answered(let milliseconds)?: StatusPill(text: "\(milliseconds) ms", tone: .good)
                            default: StatusPill(text: "No answer", tone: .bad)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct Outcome {
        let id: String
        let kind: String
        let setting: String
        let result: (text: String, tone: StatusTone)?
    }

    private func outcomes(_ profile: NetworkProfile, active: Bool) -> [Outcome] {
        let failed = manager.errorMessage != nil
        func applied() -> (text: String, tone: StatusTone)? {
            guard active else { return nil }
            return failed ? ("Not applied", .bad) : ("Applied", .good)
        }
        var list: [Outcome] = []
        if profile.dnsServers.isEmpty {
            list.append(Outcome(id: "dns", kind: "DNS", setting: "System DNS (unchanged)", result: nil))
        } else {
            let preset = DNSPreset.all.first { $0.servers == profile.dnsServers }
            list.append(Outcome(id: "dns", kind: "DNS", setting: "\(preset?.name ?? "Custom") · \(profile.dnsServers.joined(separator: ", "))", result: applied()))
        }
        if profile.tunnelActions.isEmpty {
            list.append(Outcome(id: "tunnels", kind: "Tunnels", setting: "No tunnel actions", result: nil))
        }
        for action in profile.tunnelActions {
            let tunnel = tunnels.first { $0.id == action.tunnelID }
            let name = tunnel?.name ?? "missing tunnel"
            let done = tunnel.map { action.kind == .connect ? $0.isActive : !$0.isActive } ?? false
            let result: (text: String, tone: StatusTone)? = !active ? nil
                : tunnel == nil ? ("Tunnel missing", .bad)
                : done ? (action.kind == .connect ? "Connected" : "Disconnected", .good)
                : (action.kind == .connect ? "Not connected yet" : "Still connected", .warn)
            list.append(Outcome(id: "tunnel-\(action.tunnelID)", kind: "Tunnel", setting: "\(action.kind.displayName) \(name)", result: result))
        }
        if let shortcut = profile.shortcutName {
            list.append(Outcome(id: "shortcut", kind: "Shortcut", setting: "Run “\(shortcut)” once", result: active ? ("Ran when it became active", .neutral) : nil))
        } else {
            list.append(Outcome(id: "shortcut", kind: "Shortcut", setting: "None", result: nil))
        }
        if let proxy = profile.proxy {
            let text: String
            switch proxy.mode {
            case .off: text = "No proxy"
            case .automatic: text = "Automatic · \(proxy.autoConfigURL ?? "?")"
            case .manual:
                text = "Manual · " + ([proxy.web, proxy.secureWeb, proxy.socks].compactMap { $0 }.map { "\($0.host):\($0.port)" }.joined(separator: ", "))
            }
            list.append(Outcome(id: "proxy", kind: "Proxy", setting: text, result: applied()))
        } else {
            list.append(Outcome(id: "proxy", kind: "Proxy", setting: "No proxy change", result: nil))
        }
        return list
    }

    private func move(_ profile: NetworkProfile, by offset: Int) {
        var updated = manager.profiles
        guard let index = updated.firstIndex(where: { $0.id == profile.id }),
              updated.indices.contains(index + offset) else { return }
        updated.swapAt(index, index + offset)
        Task { await manager.save(updated) }
    }

    // MARK: Text

    private func matchText(_ profile: NetworkProfile) -> String { NetworkProfileText.match(profile.match) }

    private func outcomeChips(_ profile: NetworkProfile) -> String {
        var chips: [String] = []
        if !profile.dnsServers.isEmpty { chips.append("DNS") }
        if !profile.tunnelActions.isEmpty { chips.append("Tunnel") }
        if profile.shortcutName != nil { chips.append("Shortcut") }
        if profile.proxy != nil { chips.append("Proxy") }
        return chips.isEmpty ? "No actions" : chips.joined(separator: " · ")
    }
}

/// Plain-language descriptions shared by the list and the editor's summary sentence.
enum NetworkProfileText {
    static func match(_ match: AutoConnectNetworkMatch) -> String {
        var places: [String] = []
        if match.interface != .ethernet {
            places.append(match.wifiSSIDs.isEmpty ? "Any Wi-Fi" : "Wi-Fi: " + match.wifiSSIDs.joined(separator: ", "))
        }
        if match.interface != .wifi {
            places.append(match.ethernetSubnets.isEmpty ? "Any Ethernet" : "Ethernet: " + match.ethernetSubnets.joined(separator: ", "))
        }
        return places.joined(separator: " · ")
    }

    static func actions(_ profile: NetworkProfile, tunnels: [Tunnel]) -> [String] {
        var actions: [String] = []
        if !profile.dnsServers.isEmpty {
            let preset = DNSPreset.all.first { $0.servers == profile.dnsServers }
            actions.append("set DNS to \(preset?.name ?? profile.dnsServers.joined(separator: ", "))")
        }
        for action in profile.tunnelActions {
            let name = tunnels.first { $0.id == action.tunnelID }?.name ?? "a missing tunnel"
            actions.append("\(action.kind.displayName.lowercased()) \(name)")
        }
        if let proxy = profile.proxy {
            switch proxy.mode {
            case .off: actions.append("turn the proxy off")
            case .automatic: actions.append("use a proxy PAC file")
            case .manual: actions.append("set a manual proxy")
            }
        }
        if let shortcut = profile.shortcutName { actions.append("run the Shortcut “\(shortcut)”") }
        return actions
    }
}

struct NetworkProfileEditor: View {
    private static let keepProxy = "keep"
    private static let customDNS = "custom"
    private static let noDNS = "none"

    @Environment(\.dismiss) private var dismiss
    @State private var draft: NetworkProfile
    @State private var ssids: String
    @State private var subnets: String
    @State private var dnsChoice: String
    @State private var customServers: String
    @State private var shortcut: String
    @State private var tunnelActions: [UUID: ProfileTunnelAction.Kind]
    // Proxy: "keep" leaves the system's proxy alone; the others set one.
    @State private var proxyChoice: String
    @State private var webHost: String
    @State private var webPort: String
    @State private var secureHost: String
    @State private var securePort: String
    @State private var socksHost: String
    @State private var socksPort: String
    @State private var pacURL: String
    @State private var bypass: String
    @State private var placeAtTop = false
    let isNew: Bool
    let currentSSID: String?
    let tunnels: [Tunnel]
    @ObservedObject var manager: NetworkProfileManager
    let onSave: (NetworkProfile, Bool) -> Void

    init(profile: NetworkProfile, isNew: Bool = false, currentSSID: String?, tunnels: [Tunnel], manager: NetworkProfileManager,
         onSave: @escaping (NetworkProfile, Bool) -> Void) {
        _draft = State(initialValue: profile)
        _ssids = State(initialValue: profile.match.wifiSSIDs.joined(separator: "\n"))
        _subnets = State(initialValue: profile.match.ethernetSubnets.joined(separator: "\n"))
        let preset = DNSPreset.all.first { $0.servers == profile.dnsServers }
        _dnsChoice = State(initialValue: profile.dnsServers.isEmpty ? Self.noDNS : preset?.id ?? Self.customDNS)
        _customServers = State(initialValue: preset == nil ? profile.dnsServers.joined(separator: ", ") : "")
        _shortcut = State(initialValue: profile.shortcutName ?? "")
        _tunnelActions = State(initialValue: Dictionary(profile.tunnelActions.map { ($0.tunnelID, $0.kind) },
                                                        uniquingKeysWith: { first, _ in first }))
        let proxy = profile.proxy
        _proxyChoice = State(initialValue: proxy?.mode.rawValue ?? Self.keepProxy)
        _webHost = State(initialValue: proxy?.web?.host ?? "")
        _webPort = State(initialValue: proxy?.web.map { String($0.port) } ?? "")
        _secureHost = State(initialValue: proxy?.secureWeb?.host ?? "")
        _securePort = State(initialValue: proxy?.secureWeb.map { String($0.port) } ?? "")
        _socksHost = State(initialValue: proxy?.socks?.host ?? "")
        _socksPort = State(initialValue: proxy?.socks.map { String($0.port) } ?? "")
        _pacURL = State(initialValue: proxy?.autoConfigURL ?? "")
        _bypass = State(initialValue: (proxy?.bypass ?? []).joined(separator: ", "))
        self.isNew = isNew
        self.currentSSID = currentSSID
        self.tunnels = tunnels
        self.manager = manager
        self.onSave = onSave
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var dnsServers: [String]? {
        switch dnsChoice {
        case Self.noDNS: return []
        case Self.customDNS:
            guard let servers = NetworkProfile.parseDNSServers(customServers), !servers.isEmpty else { return nil }
            return servers
        default: return DNSPreset.all.first { $0.id == dnsChoice }?.servers
        }
    }

    /// The proxy the form describes. nil with a problem means the form is incomplete.
    private var proxyResult: (settings: ProxySettings?, problem: String?) {
        guard let mode = ProxySettings.Mode(rawValue: proxyChoice) else { return (nil, nil) }
        var settings = ProxySettings(mode: mode)
        func endpoint(_ host: String, _ port: String) -> ProxyEndpoint?? {
            let host = host.trimmingCharacters(in: .whitespaces), port = port.trimmingCharacters(in: .whitespaces)
            if host.isEmpty, port.isEmpty { return .some(nil) }
            guard let number = Int(port) else { return nil }
            return .some(ProxyEndpoint(host: host, port: number))
        }
        switch mode {
        case .off:
            break
        case .manual:
            guard let web = endpoint(webHost, webPort), let secure = endpoint(secureHost, securePort),
                  let socks = endpoint(socksHost, socksPort) else { return (nil, "Each proxy port must be a number.") }
            settings.web = web
            settings.secureWeb = secure
            settings.socks = socks
            settings.bypass = bypass.split { $0 == "," || $0.isWhitespace }.map(String.init)
        case .automatic:
            settings.autoConfigURL = pacURL.trimmingCharacters(in: .whitespaces)
        }
        return (settings, settings.problem)
    }

    private var subnetsAreValid: Bool { lines(subnets).allSatisfy { IPSubnet($0) != nil } }
    private var nameIsSet: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var nameIsUnique: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespaces).lowercased()
        return !manager.profiles.contains { $0.id != draft.id && $0.name.lowercased() == name }
    }
    private var proxyIsValid: Bool { proxyChoice == Self.keepProxy || proxyResult.problem == nil }
    private var canSave: Bool { nameIsSet && nameIsUnique && dnsServers != nil && subnetsAreValid && proxyIsValid }

    /// The profile as the form describes it, even while incomplete, for the summary and the shadow check.
    private var candidate: NetworkProfile {
        var profile = draft
        profile.name = draft.name.trimmingCharacters(in: .whitespaces)
        profile.match.enabled = true
        profile.match.wifiSSIDs = draft.match.interface == .ethernet ? [] : lines(ssids)
        profile.match.ethernetSubnets = draft.match.interface == .wifi ? [] : lines(subnets).compactMap { IPSubnet($0)?.canonicalCIDR }
        profile.dnsServers = dnsServers ?? []
        let name = shortcut.trimmingCharacters(in: .whitespaces)
        profile.shortcutName = name.isEmpty ? nil : name
        profile.proxy = proxyChoice == Self.keepProxy ? nil : proxyResult.settings
        profile.tunnelActions = tunnels.compactMap { tunnel in
            tunnelActions[tunnel.id].map { ProfileTunnelAction(tunnelID: tunnel.id, kind: $0) }
        }
        return profile
    }

    /// The profile above this one that makes it unreachable, given where it will sit in the list.
    private var shadowedBy: NetworkProfile? {
        var list = manager.profiles.filter { $0.id != draft.id }
        let at = isNew ? (placeAtTop ? 0 : list.count) : min(manager.profiles.firstIndex { $0.id == draft.id } ?? list.count, list.count)
        list.insert(candidate, at: at)
        return NetworkProfileResolver.shadowingProfile(of: candidate, in: list)
    }

    private var summarySentence: String {
        let profile = candidate
        let place = NetworkProfileText.match(profile.match).replacingOccurrences(of: ": ", with: " ")
        let what = NetworkProfileText.actions(profile, tunnels: tunnels)
        let list = what.isEmpty ? "change nothing yet" : what.joined(separator: ", ")
        return "When this Mac is on \(place), this profile will \(list)."
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(summarySentence).font(.callout)
                    if let above = shadowedBy {
                        Notice(tone: .warn, title: "It may never run",
                               message: "“\(above.name)” is above it and matches every network this profile matches.")
                    }
                } header: { Text("Summary") }

                Section("Profile") {
                    TextField("Name", text: $draft.name)
                    if isNew {
                        Toggle("Place at the top of the list", isOn: $placeAtTop)
                    }
                }

                Section("When it applies") {
                    Picker("Network", selection: $draft.match.interface) {
                        ForEach(AutoConnectInterface.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if draft.match.interface != .ethernet {
                        Text("Wi-Fi networks (one per line, empty for any)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $ssids).frame(height: 56).font(.body)
                        if let currentSSID, !lines(ssids).contains(currentSSID) {
                            Button("Add current network (\(currentSSID))") {
                                ssids = (lines(ssids) + [currentSSID]).joined(separator: "\n")
                            }
                        }
                    }
                    if draft.match.interface != .wifi {
                        Text("Ethernet subnets (one per line, empty for any)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $subnets).frame(height: 56).font(.body.monospaced())
                        if !subnetsAreValid {
                            Text("Use CIDR notation such as 192.0.2.0/24.").font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section("What it does") {
                    Picker("DNS", selection: $dnsChoice) {
                        Text("Leave unchanged").tag(Self.noDNS)
                        ForEach(DNSPreset.all) { Text($0.name).tag($0.id) }
                        Text("Custom").tag(Self.customDNS)
                    }
                    if dnsChoice == Self.customDNS {
                        TextField("IP addresses, separated by commas", text: $customServers)
                        if dnsServers == nil {
                            Text("Enter one to eight IPv4 or IPv6 addresses.").font(.caption).foregroundStyle(.red)
                        }
                    }
                    if let servers = dnsServers, !servers.isEmpty {
                        dnsTest(servers)
                    }
                    TextField("Shortcut to run (optional)", text: $shortcut)
                    Picker("Proxy", selection: $proxyChoice) {
                        Text("Leave unchanged").tag(Self.keepProxy)
                        ForEach(ProxySettings.Mode.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                    }
                    if proxyChoice == ProxySettings.Mode.manual.rawValue {
                        proxyRow("HTTP", host: $webHost, port: $webPort)
                        proxyRow("HTTPS", host: $secureHost, port: $securePort)
                        proxyRow("SOCKS", host: $socksHost, port: $socksPort)
                        TextField("Bypass (comma separated, e.g. *.local, 10.0.0.0/8)", text: $bypass)
                    }
                    if proxyChoice == ProxySettings.Mode.automatic.rawValue {
                        TextField("PAC file address (https://…)", text: $pacURL)
                    }
                    if proxyChoice != Self.keepProxy, let problem = proxyResult.problem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    if proxyChoice != Self.keepProxy {
                        Text("Set on the network the Mac is using, and put back when the profile ends. Needs an administrator.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !tunnels.isEmpty {
                    Section("Tunnels (once, when the profile becomes active)") {
                        ForEach(tunnels) { tunnel in
                            Picker(tunnel.name, selection: tunnelActionBinding(tunnel.id)) {
                                Text("Leave alone").tag(ProfileTunnelAction.Kind?.none)
                                ForEach(ProfileTunnelAction.Kind.allCases, id: \.self) {
                                    Text($0.displayName).tag(ProfileTunnelAction.Kind?.some($0))
                                }
                            }
                        }
                    }
                }

                Section("Validation") {
                    Checklist(items: [
                        (nameIsSet && nameIsUnique, "Profile name is set and unique"),
                        (subnetsAreValid, "Network entries are valid"),
                        (dnsServers != nil, "DNS servers are IP addresses (1 to 8, no names)"),
                        (proxyIsValid, "Proxy settings are valid"),
                    ])
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .sheetFrame(width: 540, height: 820)
    }

    private func proxyRow(_ title: String, host: Binding<String>, port: Binding<String>) -> some View {
        HStack {
            TextField(title, text: host)
            TextField("Port", text: port).frame(width: 70)
        }
    }

    private func tunnelActionBinding(_ id: UUID) -> Binding<ProfileTunnelAction.Kind?> {
        Binding(get: { tunnelActions[id] }, set: { tunnelActions[id] = $0 })
    }

    @ViewBuilder
    private func dnsTest(_ servers: [String]) -> some View {
        HStack {
            Button(manager.isTestingDNS ? "Testing…" : "Test DNS") { Task { await manager.testDNS(servers) } }
                .disabled(manager.isTestingDNS)
            Spacer()
        }
        ForEach(servers, id: \.self) { server in
            if let outcome = manager.dnsTestResults[server] {
                HStack {
                    Text(server).font(.caption.monospaced())
                    Spacer()
                    switch outcome {
                    case .answered(let milliseconds): Text("\(milliseconds) ms").font(.caption).foregroundStyle(.green)
                    case .failed: Text("No answer").font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func save() {
        guard dnsServers != nil else { return }
        onSave(candidate, placeAtTop)
        dismiss()
    }
}
