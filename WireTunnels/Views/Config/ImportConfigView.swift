import SwiftUI
import UniformTypeIdentifiers

private enum ImportDestination: String, CaseIterable, Identifiable {
    case personal = "My Tunnels"
    case managed = "Visible to All Users"

    var id: Self { self }
}

struct ImportConfigView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) var dismiss

    @State private var isImporting = false
    @State private var isProcessing = false
    @State private var error: String? = nil
    @State private var successName: String? = nil
    @State private var selectedURL: URL? = nil
    @State private var selectedWarnings: [ConfigWarning] = []
    @State private var isDragTargeted = false
    @State private var destination: ImportDestination = .personal

    private var confType: UTType {
        UTType(filenameExtension: "conf") ?? .plainText
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Import WireGuard Config")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select a .conf file")
                            .font(.subheadline.weight(.medium))

                        Text("Choose a WireGuard configuration file (.conf) to import. The file will be validated and added to your tunnel list.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Destination", selection: $destination) {
                        ForEach(ImportDestination.allCases) { destination in
                            Text(destination.rawValue).tag(destination)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(isProcessing)

                    if destination == .managed {
                        Label("Stored once for this Mac. Any local user can see it; only administrators can modify it.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Drop zone — click to browse, or drag a .conf file onto it
                    Button {
                        isImporting = true
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: isDragTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                                .font(.system(size: 36))
                                .foregroundStyle(isDragTargeted ? Color.accentColor : Color.accentColor)
                            Text(isDragTargeted ? "Drop to Import" : "Drop .conf here or Click to Browse")
                                .font(.body.weight(.medium))
                            Text("Supports .conf files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(24)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isDragTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    isDragTargeted ? Color.accentColor : Color.accentColor.opacity(0.4),
                                    style: StrokeStyle(lineWidth: isDragTargeted ? 2 : 1.5, dash: isDragTargeted ? [] : [6])
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                    .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                        handleDrop(providers: providers)
                    }

                    // Selected file display
                    if let url = selectedURL {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(.body.weight(.medium))
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Success state
                    if let name = successName {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import Successful")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.green)
                                Text("Tunnel \"\(name)\" has been added.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Error state
                    if let errMsg = error {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Import Failed")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.red)
                                Text(errMsg)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Active warnings
                    if !selectedWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Configuration Warnings")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.orange)

                            ForEach(selectedWarnings, id: \.rawValue) { warning in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(warning.rawValue)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if isProcessing {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing configuration…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Bottom buttons
            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if selectedURL != nil && successName == nil {
                    Button("Import") {
                        performImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 480, height: 580)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [confType, .plainText]
        ) { result in
            switch result {
            case .success(let url):
                selectedURL = url
                successName = nil
                error = nil
                do {
                    let parsed = try tunnelManager.inspectConfig(at: url)
                    selectedWarnings = parsed.warnings
                    if !parsed.isValid {
                        error = ConfigManagementError
                            .invalidConfiguration(parsed.validationErrors)
                            .localizedDescription
                    }
                } catch {
                    self.error = error.localizedDescription
                    selectedWarnings = []
                }
                performImport()
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "conf" else {
                DispatchQueue.main.async {
                    self.error = "Only .conf files are supported."
                }
                return
            }
            DispatchQueue.main.async {
                self.selectedURL = url
                self.successName = nil
                self.error = nil
                do {
                    let parsed = try self.tunnelManager.inspectConfig(at: url)
                    self.selectedWarnings = parsed.warnings
                    if !parsed.isValid {
                        self.error = ConfigManagementError
                            .invalidConfiguration(parsed.validationErrors)
                            .localizedDescription
                    }
                } catch {
                    self.error = error.localizedDescription
                    self.selectedWarnings = []
                }
                self.performImport()
            }
        }
        return true
    }

    private func performImport() {
        guard let url = selectedURL else { return }
        isProcessing = true
        error = nil
        successName = nil

        Task {
            do {
                switch destination {
                case .personal:
                    try await tunnelManager.importConfig(from: url)
                case .managed:
                    try await tunnelManager.importManagedConfig(from: url)
                }
                selectedWarnings = try tunnelManager.inspectConfig(at: url).warnings
                let name = url.deletingPathExtension().lastPathComponent
                successName = name
            } catch {
                self.error = error.localizedDescription
            }
            isProcessing = false
        }
    }
}
