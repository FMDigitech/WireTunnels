import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ImportDestination: String, CaseIterable, Identifiable {
    case personal = "My Tunnels"
    case managed = "Visible to All Users"

    var id: Self { self }

    var detail: String {
        switch self {
        case .personal: return "Private to your account on this Mac."
        case .managed: return "Stored once for this Mac. Any local user can see it; only administrators can modify it."
        }
    }
}

/// Import Config: source → validate → review → import. Nothing is added until the review is confirmed.
struct ImportConfigView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var navigation: DashboardNavigation
    @Environment(\.dismiss) var dismiss

    /// Opens the Advanced Editor with the config text and the chosen name, so errors can be fixed there.
    var onFixInEditor: ((_ config: String, _ name: String) -> Void)?

    private struct Loaded {
        let sourceName: String
        let isQR: Bool
        let text: String
        let reading: ConfigReading
        let parsed: ParsedConfig
        /// The reader and the parser must both accept it: the parser decides what can be stored.
        var isReady: Bool { reading.errors.isEmpty && parsed.isValid }
        var notes: [String] { reading.diagnostics.filter { $0.severity != .error }.map(\.message) }
    }

    private struct Imported {
        let name: String
        let usesAmneziaWG: Bool
        let destination: ImportDestination
        let tunnelID: UUID?
    }

    @State private var isChoosingFile = false
    @State private var isProcessing = false
    @State private var error: String? = nil
    @State private var loaded: Loaded? = nil
    @State private var imported: Imported? = nil
    @State private var tunnelName = ""
    @State private var destination: ImportDestination = .personal
    @State private var isDragTargeted = false

    private var confType: UTType {
        UTType(filenameExtension: "conf") ?? .plainText
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp"]

    private static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private var isAdministrator: Bool { tunnelManager.currentUserIsAdministrator }
    private var step: Int { imported != nil ? 4 : loaded == nil ? 1 : loaded?.isReady == true ? 3 : 2 }
    private var nameProblem: String? { TunnelFormChecks.nameProblem(tunnelName, existing: tunnelManager.tunnels.map(\.name)) }
    private var canImport: Bool {
        loaded?.isReady == true && nameProblem == nil && !isProcessing && (destination == .personal || isAdministrator)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Config").font(.title3.bold())
                    Text("Add a WireGuard configuration to your tunnel list and set it up for use.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            steps
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) { leftColumn }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 16) { rightColumn }
                        .frame(width: 330, alignment: .leading)
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .sheetFrame(width: 900, height: 660)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [confType, .plainText, .image]
        ) { result in
            switch result {
            case .success(let url): handleFile(url)
            case .failure(let err): error = err.localizedDescription
            }
        }
    }

    // MARK: - Steps

    private var steps: some View {
        HStack(spacing: 24) {
            stepItem(1, "Source", "Provide .conf or QR code")
            stepItem(2, "Validate", "Check the configuration")
            stepItem(3, "Review", "Confirm and import")
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Progress")
    }

    private func stepItem(_ number: Int, _ title: String, _ subtitle: String) -> some View {
        let isCurrent = step == number, isDone = step > number
        return HStack(spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle\(isCurrent ? ".fill" : "")")
                .font(.title3)
                .foregroundStyle(isDone ? Color.green : isCurrent ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title), \(isDone ? "done" : isCurrent ? "current" : "to do")")
    }

    // MARK: - Left column

    @ViewBuilder
    private var leftColumn: some View {
        if let imported {
            Notice(tone: .good, title: "Import successful",
                   message: "Tunnel “\(imported.name)” has been added\(imported.destination == .managed ? " and is visible to all users" : ""). It runs on \(TunnelEngine(usesAmneziaWG: imported.usesAmneziaWG).displayName), chosen from the config. It is not connected yet.")
        } else if let loaded {
            fileCard(loaded)
            if loaded.isReady { reviewStep(loaded) } else { problemsStep(loaded) }
        } else {
            sourceStep
        }
        if let error {
            Notice(tone: .bad, title: "Import failed", message: error)
        }
        if isProcessing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Importing configuration…").foregroundStyle(.secondary)
            }
        }
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneSectionHeader(title: "Choose what to import",
                              note: "A WireGuard configuration file (.conf) or a QR code image. It is checked first; nothing is added until you confirm.")

            // Drop zone — click to browse, or drag a .conf file onto it
            Button {
                isChoosingFile = true
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: isDragTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                    Text(isDragTargeted ? "Drop to Import" : "Drop a .conf file here or click to browse")
                        .font(.body.weight(.medium))
                    Text("Supports .conf files and QR code images")
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
            .accessibilityLabel("Drop a file here or click to browse")
            .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                handleDrop(providers: providers)
            }

            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste QR Code from Clipboard", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
        }
    }

    private func fileCard(_ loaded: Loaded) -> some View {
        HStack(spacing: 10) {
            Image(systemName: loaded.isQR ? "qrcode" : "doc.text.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(loaded.sourceName).font(.body.weight(.medium))
                Text("\(loaded.isQR ? "Read from a QR code" : "Configuration file") · \(loaded.text.components(separatedBy: "\n").count) lines")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if imported == nil {
                Button("Choose another") { startOver() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Step 2: the file cannot be imported. Each problem says where and how to fix it.
    private func problemsStep(_ loaded: Loaded) -> some View {
        let errors = loaded.reading.errors
        return VStack(alignment: .leading, spacing: 12) {
            Notice(tone: .bad, title: "Can’t import yet",
                   message: errors.isEmpty
                       ? "The configuration is not valid. Nothing was added."
                       : "\(errors.count) problem\(errors.count == 1 ? "" : "s") to fix. Nothing was added.")
            if !errors.isEmpty {
                VStack(spacing: 0) {
                    ForEach(errors) { item in
                        HStack(alignment: .top, spacing: 10) {
                            StatusPill(text: "Error", tone: .bad).frame(width: 70, alignment: .leading)
                            Text("Line \(item.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.message).font(.callout.weight(.medium))
                                if !item.hint.isEmpty { Text(item.hint).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        Divider()
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    /// Step 3: valid. Review the name and destination, then import.
    private func reviewStep(_ loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            let notes = loaded.notes
            Notice(tone: .good, title: "Ready to import",
                   message: "The configuration is valid\(notes.isEmpty ? "" : " (\(notes.count) thing\(notes.count == 1 ? "" : "s") to know)"). Review it, then import.")
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Configuration warnings", systemImage: StatusTone.warn.icon)
                        .font(.callout.weight(.semibold)).foregroundStyle(StatusTone.warn.color)
                    ForEach(notes, id: \.self) { Text("• \($0)").font(.callout) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StatusTone.warn.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Tunnel name").font(.subheadline.weight(.medium))
                    Text("*").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                TextField("Tunnel name", text: $tunnelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                    .disabled(isProcessing)
                if let nameProblem {
                    Label(nameProblem, systemImage: StatusTone.bad.icon).font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination").font(.caption).foregroundStyle(.secondary)
                ForEach(ImportDestination.allCases) { destinationRow($0) }
            }
        }
    }

    private func destinationRow(_ choice: ImportDestination) -> some View {
        let isSelected = destination == choice
        let needsAdmin = choice == .managed && !isAdministrator
        return Button {
            destination = choice
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.rawValue).font(.callout.weight(.medium))
                    Text(choice.detail + (needsAdmin ? " Needs an administrator account." : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isProcessing || needsAdmin)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Right column

    @ViewBuilder
    private var rightColumn: some View {
        checklist
        setupPreview
        Text("Nothing is imported or connected until you press Import. Quality and traffic appear after the first connection.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var checklist: some View {
        let rows: [(String, DiagnosticCategory?)] = [
            ("Configuration loaded", nil),
            ("Syntax is readable", .syntax),
            ("Content is safe (no scripts, no hidden characters)", .safety),
            ("Required values are present", .required),
            ("Keys and addresses have the right format", .format),
            ("Network settings were read", nil)
        ]
        let errors = loaded?.reading.errors ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preflight checklist").font(.headline)
                Spacer()
                Text(loaded == nil ? "Waiting for a file" : loaded?.isReady == true ? "All good"
                     : "\(max(errors.count, 1)) problem\(errors.count > 1 ? "s" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let found = row.1.flatMap { category in errors.first { $0.category == category } }
                let isLast = index == rows.count - 1
                let pending = loaded == nil || (isLast && loaded?.isReady != true)
                let tone: StatusTone = pending ? .neutral : found != nil ? .bad : .good
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: pending ? "circle" : tone.icon).foregroundStyle(tone.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.0).font(.callout.weight(.medium))
                        if let found { Text(found.message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var setupPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What it would set up").font(.headline)
                Spacer()
                StatusPill(text: "Preview · nothing imported", tone: .neutral, showsIcon: false)
            }
            if let loaded, loaded.isReady {
                let parsed = loaded.parsed
                let routes = parsed.allowedIPs.joined(separator: ", ")
                InfoRow(label: "Runs on", value: "\(TunnelEngine(usesAmneziaWG: parsed.usesAmneziaWG).displayName) (chosen from the config)")
                InfoRow(label: "Address", value: parsed.address.joined(separator: ", "), monospaced: true)
                InfoRow(label: "DNS", value: parsed.dns.isEmpty ? "not set" : parsed.dns.joined(separator: ", "), monospaced: !parsed.dns.isEmpty)
                InfoRow(label: "Endpoint", value: parsed.endpoint ?? "not set", monospaced: parsed.endpoint != nil)
                InfoRow(label: "Routes", value: routes + (parsed.allowedIPs.contains("0.0.0.0/0") ? " (all traffic)" : ""), monospaced: true)
                let competing = tunnelManager.tunnels.filter { $0.isActive && $0.allowedIPs.contains("0.0.0.0/0") }
                if parsed.allowedIPs.contains("0.0.0.0/0") && !competing.isEmpty {
                    Notice(tone: .warn, title: "Another tunnel already routes all traffic",
                           message: "Connecting both makes them compete for the default route.")
                }
            } else {
                Text("The routes, DNS servers and engine appear here once a valid file is loaded. Private keys are never shown.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let imported {
                Button("Import another") { startOver() }
                    .buttonStyle(.bordered)
                if let id = imported.tunnelID {
                    Button("Open tunnel") {
                        navigation.requestTunnel(id)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            } else if let loaded {
                if !loaded.isReady {
                    Button("Choose another file") { startOver() }
                        .buttonStyle(.bordered)
                    if let onFixInEditor {
                        Button("Fix in the Advanced Editor") {
                            onFixInEditor(loaded.text, tunnelName)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Import") { performImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canImport)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Loading a source

    private func startOver() {
        loaded = nil
        imported = nil
        error = nil
    }

    private func load(sourceName: String, text: String, isQR: Bool) {
        let base = isQR ? "qr-import" : String(sourceName.replacingOccurrences(of: #"\.conf$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "[^A-Za-z0-9 ._-]", with: "_", options: .regularExpression).prefix(40))
        error = nil
        imported = nil
        tunnelName = base
        loaded = Loaded(sourceName: sourceName, isQR: isQR, text: text,
                        reading: ConfigDiagnostics.read(text), parsed: WireGuardConfigParser().parse(string: text))
    }

    private func handleFile(_ url: URL) {
        if Self.isImageFile(url) {
            if let image = NSImage(contentsOf: url) {
                handleQRImage(image)
            } else {
                error = "Unable to read that image."
            }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            error = "Unable to read that file."
            return
        }
        load(sourceName: url.lastPathComponent, text: text, isQR: false)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                guard let url else {
                    self.error = "Unsupported file."
                    return
                }
                if Self.isImageFile(url) || url.pathExtension.lowercased() == "conf" {
                    self.handleFile(url)
                } else {
                    self.error = "Only .conf files and QR code images are supported."
                }
            }
        }
        return true
    }

    private func pasteFromClipboard() {
        guard let image = NSImage(pasteboard: .general) else {
            error = "No image found on the clipboard."
            return
        }
        handleQRImage(image)
    }

    private func handleQRImage(_ image: NSImage) {
        guard let decoded = QRCodeService.decode(from: image) else {
            error = "No QR code found in that image."
            return
        }
        load(sourceName: "QR code", text: decoded, isQR: true)
    }

    // MARK: - Import

    private func performImport() {
        guard canImport, let loaded else { return }
        let name = tunnelName.trimmingCharacters(in: .whitespaces)
        let target = destination
        isProcessing = true
        error = nil

        Task {
            defer { isProcessing = false }
            do {
                // The chosen name is the file name, so a copy is written and removed afterwards.
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent(name).appendingPathExtension("conf")
                guard FileManager.default.createFile(atPath: url.path, contents: Data(loaded.text.utf8),
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                switch target {
                case .personal: try await tunnelManager.importConfig(from: url)
                case .managed: try await tunnelManager.importManagedConfig(from: url)
                }
                let stored = ConfigStorageService.displayName(for: name)
                imported = Imported(name: stored, usesAmneziaWG: loaded.parsed.usesAmneziaWG, destination: target,
                                    tunnelID: tunnelManager.tunnels.first { $0.name == stored }?.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
