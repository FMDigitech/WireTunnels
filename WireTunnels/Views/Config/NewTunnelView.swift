import SwiftUI
import AppKit

struct NewTunnelView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) var dismiss

    private enum Mode { case basic, advanced }
    private typealias Field = TunnelFormChecks.Field

    @State private var mode: Mode
    @State private var fields: TunnelFormFields
    @State private var advancedContent: String
    @State private var touched: Set<Field> = []
    @FocusState private var focus: Field?

    // UI state
    @State private var isSaving = false
    @State private var isConnecting = false
    @State private var error: String? = nil
    @State private var switchRefusal: String? = nil
    @State private var revealLine: Int? = nil
    @State private var generatedPublicKey: String = ""
    @State private var generatedPrivateKey: String = ""
    @State private var isGeneratingKeys = false
    @State private var showPrivateKey = false

    /// `initialConfig` opens the Advanced Editor with that text, e.g. from "Fix in the Advanced Editor" in Import Config.
    init(initialConfig: String? = nil, initialName: String = "") {
        _mode = State(initialValue: initialConfig == nil ? .basic : .advanced)
        _advancedContent = State(initialValue: initialConfig ?? "")
        var fields = TunnelFormFields()
        fields.name = initialName
        _fields = State(initialValue: fields)
    }

    // MARK: Derived state

    private var existingNames: [String] { tunnelManager.tunnels.map(\.name) }
    private var otherFullTunnels: [String] {
        tunnelManager.tunnels.filter { $0.isActive && $0.allowedIPs.contains("0.0.0.0/0") }.map(\.name)
    }
    private var checks: TunnelFormChecks { TunnelFormChecks(fields, existingNames: existingNames, otherFullTunnels: otherFullTunnels) }
    private var reading: ConfigReading { ConfigDiagnostics.read(advancedContent) }
    private var advancedNameProblem: String? { TunnelFormChecks.nameProblem(fields.name, existing: existingNames) }

    private var effectiveConfig: String { mode == .basic ? fields.config() : advancedContent }

    private var canSave: Bool {
        mode == .basic ? checks.canSave : advancedNameProblem == nil && reading.errors.isEmpty
    }
    private var canConnect: Bool {
        mode == .basic ? checks.canConnect : canSave && !reading.hasMissingEndpoint
    }
    private var isBusy: Bool { isSaving || isConnecting }

    /// Why Save or Save & Connect is off, said next to the buttons.
    private var disabledReason: String {
        if mode == .basic {
            if !checks.canSave { return "Complete the name, keys, address and allowed IPs to save." }
        } else if fields.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Give the tunnel a name to save."
        } else if let problem = advancedNameProblem {
            return problem
        } else if !reading.errors.isEmpty {
            return "Fix \(reading.errors.count) error\(reading.errors.count == 1 ? "" : "s") to save."
        }
        if !canConnect { return "Save & Connect needs an endpoint." }
        return tunnelManager.connectionUnavailableReason ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Tunnel").font(.title3.bold())
                    Text(mode == .basic
                         ? "Fill in the form and WireTunnels writes the WireGuard configuration for you."
                         : "Write or paste a WireGuard config. WireTunnels reads it as you type and points to any line that needs attention.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Picker("How to create", selection: modeBinding) {
                Text("Basic Form").tag(Mode.basic)
                Text("Advanced Editor").tag(Mode.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .padding(.bottom, 10)

            if let reason = switchRefusal {
                HStack(alignment: .top) {
                    Notice(tone: .warn, title: "Can't switch to the Basic Form",
                           message: "\(reason) Your editor content is kept; the form would lose it.")
                    Button("Dismiss") { switchRefusal = nil }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            Divider()

            if mode == .basic { basicForm } else { advancedEditor }

            Divider()
            footer
        }
        .sheetFrame(width: 960, height: 720)
        .onChange(of: focus) { old, _ in
            if let old { touched.insert(old) }
        }
        .onChange(of: advancedContent) { _, _ in switchRefusal = nil }
        .alert("Error", isPresented: .init(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Tabs

    private var modeBinding: Binding<Mode> {
        Binding(get: { mode }, set: { switchMode(to: $0) })
    }

    private func switchMode(to newMode: Mode) {
        guard newMode != mode else { return }
        if newMode == .advanced {
            advancedContent = fields.config()
            switchRefusal = nil
            mode = .advanced
            return
        }
        // Back to the form: only when nothing typed in the editor would be lost.
        if advancedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || advancedContent == fields.config() {
            mode = .basic
            return
        }
        switch TunnelFormFields.read(config: advancedContent) {
        case .success(var read):
            read.name = fields.name
            fields = read
            switchRefusal = nil
            mode = .basic
        case .failure(let failure):
            switchRefusal = failure.reason
        }
    }

    // MARK: - Basic Form

    private var basicForm: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    FormSection(title: "General") {
                        textField("Tunnel name", .name, "My VPN", mono: false, required: true)
                    }

                    FormSection(title: "Interface") {
                        privateKeyField
                        if !generatedPublicKey.isEmpty { publicKeyNotice }
                        textField("Address", .address, "10.0.0.2/24", required: true)
                        textField("DNS", .dns, "1.1.1.1", optional: true)
                        textField("Search domains", .searchDomains, "office.lan, corp.lan", optional: true)
                    }

                    FormSection(title: "Peer (the server)") {
                        textField("Public key", .peerPublicKey, "Server public key", required: true)
                        textField("Preshared key", .presharedKey, "Optional", optional: true)
                        textField("Endpoint", .endpoint, "vpn.example.com:51820", optional: true)
                        VStack(alignment: .leading, spacing: 6) {
                            textField("Allowed IPs", .allowedIPs, "0.0.0.0/0", required: true)
                            HStack {
                                Button("All traffic (0.0.0.0/0, ::/0)") { fields.allowedIPs = "0.0.0.0/0, ::/0" }
                                    .buttonStyle(.bordered).controlSize(.small)
                                Text("or list only the networks to reach, such as 10.0.0.0/24")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        textField("Keepalive (seconds)", .keepalive, "25", optional: true, width: 140)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 16) {
                    configurationCheck
                    ForEach(checks.warnings, id: \.self) { Notice(tone: .warn, title: $0) }
                    if checks.canSave && checks.endpointMissing {
                        Notice(tone: .info, title: "No endpoint",
                               message: "You can save, but the tunnel cannot connect until you add one (host:port).")
                    }
                    preview
                }
                .frame(width: 330)
            }
            .padding(20)
        }
    }

    private var privateKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            labelRow("Private key", required: true)
            HStack {
                Group {
                    if showPrivateKey {
                        TextField("Base64 encoded key", text: $fields.privateKey)
                    } else {
                        SecureField("Base64 encoded key", text: $fields.privateKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($focus, equals: .privateKey)
                .onChange(of: fields.privateKey) { _, newValue in
                    if !generatedPrivateKey.isEmpty && newValue != generatedPrivateKey {
                        generatedPrivateKey = ""
                        generatedPublicKey = ""
                    }
                }
                Button(showPrivateKey ? "Hide" : "Show") { showPrivateKey.toggle() }
                    .buttonStyle(.bordered)
                    .help(showPrivateKey ? "Hide private key" : "Show private key")
                Button {
                    generateKeyPair()
                } label: {
                    if isGeneratingKeys { ProgressView().controlSize(.small) } else { Text("Generate") }
                }
                .buttonStyle(.bordered)
                .disabled(isGeneratingKeys)
                .help("Generate a WireGuard private/public key pair")
            }
            problemText(.privateKey)
            Text("Stays on this Mac. It is masked here and hidden in every log and preview.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var publicKeyNotice: some View {
        Notice(tone: .info, title: "Your public key — give it to the server admin", message: generatedPublicKey)
            .overlay(alignment: .topTrailing) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(generatedPublicKey, forType: .string)
                }
                .buttonStyle(.bordered).controlSize(.small).padding(8)
            }
    }

    private func labelRow(_ label: String, required: Bool = false, optional: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            if required { Text("*").foregroundStyle(.secondary).accessibilityHidden(true) }
            if optional { Text("(optional)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func textField(_ label: String, _ field: Field, _ placeholder: String, mono: Bool = true,
                           required: Bool = false, optional: Bool = false, width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            labelRow(label, required: required, optional: optional)
            TextField(placeholder, text: $fields[dynamicMember: path(field)])
                .textFieldStyle(.roundedBorder)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .focused($focus, equals: field)
                .frame(maxWidth: width)
                .disableAutocorrection(true)
            problemText(field)
        }
    }

    /// A field's problem, shown once the field has been visited, with an icon and words.
    @ViewBuilder
    private func problemText(_ field: Field) -> some View {
        if touched.contains(field), let message = checks.problems[field] {
            Label(message, systemImage: StatusTone.bad.icon).font(.caption).foregroundStyle(.red)
        }
    }

    private func path(_ field: Field) -> WritableKeyPath<TunnelFormFields, String> {
        switch field {
        case .name: return \.name
        case .privateKey: return \.privateKey
        case .address: return \.address
        case .dns: return \.dns
        case .searchDomains: return \.searchDomains
        case .peerPublicKey: return \.peerPublicKey
        case .presharedKey: return \.presharedKey
        case .endpoint: return \.endpoint
        case .allowedIPs: return \.allowedIPs
        case .keepalive: return \.keepalive
        }
    }

    // MARK: Right column

    private var configurationCheck: some View {
        let always: [(Field, String)] = [(.name, "Tunnel name"), (.privateKey, "Private key"), (.address, "Address"),
                                         (.peerPublicKey, "Peer public key"), (.allowedIPs, "Allowed IPs")]
        let whenFilled: [(Field, String)] = [(.dns, "DNS servers"), (.searchDomains, "Search domains"),
                                             (.presharedKey, "Preshared key"), (.keepalive, "Keepalive")]
            .filter { !fields[keyPath: path($0.0)].trimmingCharacters(in: .whitespaces).isEmpty }
        let toSave = always + whenFilled
        let done = toSave.filter { checks.problems[$0.0] == nil }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Configuration check").font(.headline)
                Spacer()
                Text("\(done) of \(toSave.count) needed to save").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(toSave, id: \.0) { field, label in checkRow(field, label, toConnect: false) }
            checkRow(.endpoint, "Endpoint", toConnect: true)
        }
    }

    private func checkRow(_ field: Field, _ label: String, toConnect: Bool) -> some View {
        let value = fields[keyPath: path(field)].trimmingCharacters(in: .whitespaces)
        let problem = checks.problems[field]
        let pending = (problem != nil && value.isEmpty && !touched.contains(field)) || (toConnect && value.isEmpty)
        let tone: StatusTone = pending ? .neutral : problem == nil ? .good : .bad
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: pending ? "circle" : tone.icon).foregroundStyle(tone.color).font(.callout)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(label).font(.callout.weight(.medium))
                    if toConnect { Text("(to connect)").font(.caption).foregroundStyle(.secondary) }
                }
                if toConnect && value.isEmpty {
                    Text("Add host:port, such as vpn.example.com:51820.").font(.caption).foregroundStyle(.secondary)
                } else if let problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                    Button("Go to field") { focus = field }.buttonStyle(.link).font(.caption)
                } else {
                    Text("Looks valid").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What will be written").font(.headline)
            StatusPill(text: "Preview · keys hidden", tone: .neutral, showsIcon: false)
            Text(fields.config(maskingKeys: true))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text("Valid fields are a syntax check, not a connection test. Quality and traffic appear after the first connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Advanced Editor

    private var advancedEditor: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    labelRow("Tunnel name", required: true)
                    TextField("my_vpn", text: $fields.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                        .frame(maxWidth: 420)
                    if touched.contains(.name), let problem = advancedNameProblem {
                        Label(problem, systemImage: StatusTone.bad.icon).font(.caption).foregroundStyle(.red)
                    }
                }
                ConfigEditorView(content: $advancedContent, revealLine: $revealLine)
                    .frame(minHeight: 260, maxHeight: .infinity)
                Text("Private and preshared keys are masked in the editor and hidden in every preview and log.")
                    .font(.caption).foregroundStyle(.secondary)
                ConfigDiagnosticsList(diagnostics: reading.diagnostics, onJump: { revealLine = $0 })
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What was read").font(.headline)
                    StatusPill(text: "Parsed outline", tone: .neutral, showsIcon: false)
                    ConfigOutline(reading: reading)
                    Text("After the first connection you will see traffic, latency and loss for this tunnel. Nothing is measured before that.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 290)
        }
        .padding(20)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(disabledReason).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save(andConnect: false) }
                .buttonStyle(.bordered)
                .disabled(!canSave || isBusy)
            Button("Save & Connect") { save(andConnect: true) }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect || isBusy || !tunnelManager.canConnectTunnels)
                .help(tunnelManager.connectionUnavailableReason ?? "Save the tunnel and connect")
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func save(andConnect: Bool) {
        let displayName = ConfigStorageService.displayName(for: fields.name)

        isSaving = true
        Task {
            do {
                try await tunnelManager.createTunnel(
                    name: displayName,
                    configContent: effectiveConfig
                )

                if andConnect {
                    isConnecting = true
                    if let tunnel = tunnelManager.tunnels.first(where: { $0.name == displayName }) {
                        await tunnelManager.connectTunnel(tunnel)
                    }
                    isConnecting = false
                }

                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func generateKeyPair() {
        isGeneratingKeys = true
        Task {
            do {
                let keys = try await tunnelManager.generateKeyPair()
                generatedPrivateKey = keys.privateKey
                fields.privateKey = keys.privateKey
                generatedPublicKey = keys.publicKey
            } catch {
                self.error = error.localizedDescription
            }
            isGeneratingKeys = false
        }
    }
}

// MARK: - Supporting Views

struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)

            content
        }
    }
}
