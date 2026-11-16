import SwiftUI

/// Looks for other VPN software and for routes and DNS that fight with the active tunnels.
/// The scan reads local system state only; it sends no traffic and stores nothing.
struct NetworkDoctorView: View {
    @ObservedObject var doctor: NetworkDoctor
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var monitor: LinkQualityMonitor
    @EnvironmentObject var navigation: DashboardNavigation
    @State private var selectedID: String?

    // MARK: Findings

    private enum Area: String, CaseIterable {
        case vpn = "Other VPNs", routes = "Routes", dns = "DNS"
    }

    private func area(_ finding: NetworkFinding) -> Area {
        if finding.id.hasPrefix("product-") { return .vpn }
        if finding.id.hasPrefix("dns-") { return .dns }
        return .routes
    }

    /// Worst first, so what needs action is at the top.
    private var findings: [NetworkFinding] {
        doctor.findings.sorted { $0.severity > $1.severity }
    }

    private var selected: NetworkFinding? {
        findings.first { $0.id == selectedID } ?? findings.first
    }

    private func tone(_ severity: FindingSeverity) -> StatusTone {
        switch severity {
        case .error: return .bad
        case .warning: return .warn
        case .info: return .info
        }
    }

    private func label(_ severity: FindingSeverity) -> String {
        switch severity {
        case .error: return "Problem"
        case .warning: return "Warning"
        case .info: return "Note"
        }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                banner
                if doctor.lastScan != nil {
                    if !findings.isEmpty {
                        MasterDetail(masterFraction: 0.42, masterMin: 320, detailMin: 320, inset: 0) {
                            ScrollView { findingList.padding(4) }
                        } detail: {
                            ScrollView { if let finding = selected { detail(finding) } }
                        }
                        .frame(height: 360)
                    } else {
                        allClear
                    }
                }
                probesBlock
                Text("The scan only reads this Mac's route table, DNS settings and running apps. It sends no traffic and changes nothing, so it cannot show your public IP address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        // Scans on opening, and again whenever a tunnel connects or disconnects.
        .task(id: tunnelManager.activeTunnelCount) {
            // A tunnel that just connected needs a moment to install its routes.
            if doctor.lastScan != nil { try? await Task.sleep(for: .seconds(3)) }
            guard !Task.isCancelled else { return }
            await tunnelManager.scanNetwork()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Network Doctor").font(.title2.bold())
                Text("Checks routes, DNS and other VPN apps for anything that fights with your active tunnels.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await tunnelManager.scanNetwork() }
            } label: {
                if doctor.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            }
            .disabled(doctor.isScanning)
            .help("Reads this Mac's network settings again. It does not change anything.")
        }
    }

    private var scanNote: String {
        guard let last = doctor.lastScan else { return "" }
        let n = doctor.scannedTunnelCount
        return "Scanned \(Format.clock(last)) with \(n) active tunnel\(n == 1 ? "" : "s")"
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        let errors = findings.filter { $0.severity == .error }
        let warnings = findings.filter { $0.severity == .warning }
        if doctor.lastScan == nil || (doctor.isScanning && doctor.findings.isEmpty) {
            SummaryBanner(tone: .neutral, title: "Scanning this Mac…", detail: "Reading routes, DNS settings and running VPN apps. No traffic is sent.")
        } else if !errors.isEmpty {
            SummaryBanner(tone: .bad, title: "\(errors.count) problem\(errors.count == 1 ? "" : "s") found",
                          detail: "\(errors[0].title) · \(scanNote)") { chips }
        } else if !warnings.isEmpty {
            SummaryBanner(tone: .warn, title: "\(warnings.count) thing\(warnings.count == 1 ? "" : "s") to look at",
                          detail: "Nothing is broken, but \(warnings.count == 1 ? "this may" : "these may") affect your tunnels. \(scanNote)") { chips }
        } else if doctor.scannedTunnelCount == 0 {
            SummaryBanner(tone: .neutral, title: "Nothing to check yet",
                          detail: "Connect a tunnel and scan again to check how it shares the network. \(scanNote)") { chips }
        } else {
            SummaryBanner(tone: .good, title: "No conflicts found", detail: "No other VPN is competing for routes or DNS. \(scanNote)") { chips }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(Area.allCases, id: \.self) { area in
                let list = findings.filter { self.area($0) == area }
                let worst = list.map(\.severity).max()
                chip(area.rawValue, worst == .error ? ("Problem", .bad) : worst == .warning ? ("Warning", .warn) : ("OK", .good))
            }
            chip("Probes", !monitor.settings.enabled ? ("Off", .neutral) : degradedCount > 0 ? ("\(degradedCount) degraded", .warn) : ("OK", .good))
        }
    }

    private func chip(_ name: String, _ state: (String, StatusTone)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            StatusPill(text: state.0, tone: state.1)
        }
    }

    private var degradedCount: Int {
        tunnelManager.tunnels.filter { monitor.quality(for: $0) == .fair || monitor.quality(for: $0) == .poor }.count
    }

    // MARK: List and detail

    private var findingList: some View {
        Card(padding: 4, plain: true) {
            VStack(spacing: 0) {
                ForEach(findings) { finding in
                    Button { selectedID = finding.id } label: {
                        HStack(spacing: 12) {
                            StatusPill(text: label(finding.severity), tone: tone(finding.severity)).frame(width: 84, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.title).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
                                Text(area(finding).rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(selected?.id == finding.id ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected?.id == finding.id ? .isSelected : [])
                    if finding.id != findings.last?.id { Divider() }
                }
            }
        }
    }

    private func detail(_ finding: NetworkFinding) -> some View {
        Card(plain: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusPill(text: label(finding.severity), tone: tone(finding.severity))
                    Text(finding.title).font(.title3.weight(.semibold))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("What the scan saw").font(.headline)
                    Text(finding.detail).font(.callout).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("What to do").font(.headline)
                    Text(finding.advice ?? "Nothing to do. This is for your information.").font(.callout)
                }
                Button("Re-check this") { Task { await tunnelManager.scanNetwork() } }
                    .disabled(doctor.isScanning)
            }
        }
    }

    private var allClear: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing to fix").font(.headline)
                Text("The scan checked three things on this Mac:").font(.callout).foregroundStyle(.secondary)
                Checklist(items: [
                    (true, "Other VPN apps: none is competing with your tunnels"),
                    (true, "Routes: no overlaps and no second catch-all route"),
                    (true, "DNS: your tunnels' DNS is the one in use"),
                ])
                if doctor.scannedTunnelCount == 0 {
                    Text("No tunnel is connected, so only other VPN apps could be checked.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Optional probes

    private var probesBlock: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                PaneSectionHeader(title: "Active probes", note: "Optional · separate from the scan above, which never sends traffic")
                if !monitor.settings.enabled {
                    Text("Not measured. Latency and packet loss need the active probes, which are off.").font(.callout).foregroundStyle(.secondary)
                    Button("Turn on monitoring…") { navigation.requestSidebar(.settings) }
                } else if degradedCount > 0 {
                    Notice(tone: .warn, title: "\(degradedCount) tunnel\(degradedCount == 1 ? "" : "s") measured below Good",
                           message: "See the tunnel's Overview for latency and loss. A measurement shows that quality changed, not why.")
                } else {
                    Text("Probes are on and no connected tunnel is below Good.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
