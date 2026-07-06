import SwiftUI
import AppKit

struct NewTunnelView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab = 0

    // Basic form fields
    @State private var tunnelName: String = ""
    @State private var privateKey: String = ""
    @State private var address: String = ""
    @State private var dns: String = ""
    @State private var peerPublicKey: String = ""
    @State private var presharedKey: String = ""
    @State private var endpoint: String = ""
    @State private var allowedIPs: String = ""
    @State private var persistentKeepalive: String = ""

    // Advanced editor
    @State private var advancedContent: String = ""

    // UI state
    @State private var isSaving = false
    @State private var isConnecting = false
    @State private var error: String? = nil
    @State private var generatedPublicKey: String = ""
    @State private var generatedPrivateKey: String = ""
    @State private var isGeneratingKeys = false
    @State private var showPrivateKey = false

    private var generatedConfig: String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(address)
        \(dns.isEmpty ? "" : "DNS = \(dns)\n")
        [Peer]
        PublicKey = \(peerPublicKey)
        \(presharedKey.isEmpty ? "" : "PresharedKey = \(presharedKey)\n")Endpoint = \(endpoint)
        AllowedIPs = \(allowedIPs)
        \(persistentKeepalive.isEmpty ? "" : "PersistentKeepalive = \(persistentKeepalive)\n")
        """
    }

    private var effectiveConfig: String {
        selectedTab == 0 ? generatedConfig : advancedContent
    }

    private var canSave: Bool {
        let name = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedTab == 0 {
            return !name.isEmpty && !privateKey.isEmpty && !address.isEmpty
        } else {
            return !name.isEmpty && !advancedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("New Tunnel")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Basic Form").tag(0)
                Text("Advanced Editor").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // Content
            if selectedTab == 0 {
                basicFormView
            } else {
                advancedEditorView
            }

            Divider()

            // Bottom buttons
            bottomButtons
        }
        .frame(width: 560, height: 640)
        .alert("Error", isPresented: .init(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Basic Form

    private var basicFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                FormSection(title: "General") {
                    FormRow(label: "Tunnel Name") {
                        TextField("My VPN", text: $tunnelName)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                FormSection(title: "Interface") {
                    FormRow(label: "Private Key") {
                        HStack {
                            Group {
                                if showPrivateKey {
                                    TextField("Base64 encoded key", text: $privateKey)
                                        .font(.system(.body, design: .monospaced))
                                } else {
                                    SecureField("Base64 encoded key", text: $privateKey)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: privateKey) { _, newValue in
                                if !generatedPrivateKey.isEmpty && newValue != generatedPrivateKey {
                                    generatedPrivateKey = ""
                                    generatedPublicKey = ""
                                }
                            }
                            Button {
                                showPrivateKey.toggle()
                            } label: {
                                Image(systemName: showPrivateKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.bordered)
                            .help(showPrivateKey ? "Hide private key" : "Show private key")
                            Button {
                                generateKeyPair()
                            } label: {
                                if isGeneratingKeys {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "key.fill")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isGeneratingKeys)
                            .help("Generate a WireGuard private/public key pair")
                        }
                    }

                    if !generatedPublicKey.isEmpty {
                        FormRow(label: "Your Public Key") {
                            HStack {
                                Text(generatedPublicKey)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(generatedPublicKey, forType: .string)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    FormRow(label: "Address") {
                        TextField("10.0.0.2/24", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    FormRow(label: "DNS") {
                        TextField("1.1.1.1", text: $dns)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                FormSection(title: "Peer") {
                    FormRow(label: "Public Key") {
                        TextField("Server public key", text: $peerPublicKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    FormRow(label: "Preshared Key") {
                        TextField("Optional", text: $presharedKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    FormRow(label: "Endpoint") {
                        TextField("vpn.example.com:51820", text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    FormRow(label: "Allowed IPs") {
                        TextField("0.0.0.0/0", text: $allowedIPs)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    FormRow(label: "Keepalive") {
                        TextField("25", text: $persistentKeepalive)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Advanced Editor

    private var advancedEditorView: some View {
        VStack(spacing: 0) {
            // Name field — visible in both tabs
            HStack(alignment: .center, spacing: 12) {
                Text("Tunnel Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
                TextField("my_vpn", text: $tunnelName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ConfigEditorView(content: $advancedContent)
                .padding(8)
        }
        .onAppear {
            if advancedContent.isEmpty {
                advancedContent = generatedConfig
            }
        }
    }

    // MARK: - Bottom Buttons

    private var bottomButtons: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Save") {
                save(andConnect: false)
            }
            .buttonStyle(.bordered)
            .disabled(!canSave || isSaving || isConnecting)

            Button("Save & Connect") {
                save(andConnect: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving || isConnecting)
            .keyboardShortcut(.defaultAction)

            if isSaving || isConnecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func save(andConnect: Bool) {
        let sanitizedName = ConfigStorageService.sanitize(name: tunnelName)

        isSaving = true
        Task {
            do {
                try await tunnelManager.createTunnel(
                    name: sanitizedName,
                    configContent: effectiveConfig
                )

                if andConnect {
                    isConnecting = true
                    if let tunnel = tunnelManager.tunnels.first(where: { $0.name == sanitizedName }) {
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
                privateKey = keys.privateKey
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
