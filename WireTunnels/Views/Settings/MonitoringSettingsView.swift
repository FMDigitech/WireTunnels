import SwiftUI

/// Settings › Monitoring. Edits a draft; nothing changes until Apply, and invalid values block Apply.
struct MonitoringSettingsView: View {
    @EnvironmentObject var monitor: LinkQualityMonitor
    @State private var draft = MonitoringSettings()
    @State private var loaded = false
    @State private var justApplied = false

    private var plan: ProbePlan { draft.plan }
    private var activeTunnelNote: String { draft.destination.isEmpty ? "the tunnel's own server" : draft.destination }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $draft.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn on monitoring").font(.callout.weight(.semibold))
                    Text("Sends small test packets (pings) while a tunnel is connected, to show latency and packet loss. Speed and handshake never need this.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Group {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where to measure").font(.callout.weight(.medium))
                    TextField("Host or IP (empty = each tunnel's own server)", text: $draft.destination)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    Text(draft.destination.isEmpty
                         ? "Each tunnel's server is pinged from this Mac, outside the tunnel. It shows the path to the server, not through it."
                         : "This host is pinged through each connected tunnel. Choose a host you are happy to send pings to.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 24) {
                    Picker("How often", selection: $draft.intervalSeconds) {
                        ForEach(ProbePlan.intervals, id: \.self) { Text("Every \($0) s").tag($0) }
                    }
                    Picker("Keep history", selection: $draft.retentionHours) {
                        ForEach(ProbePlan.retentionHours, id: \.self) { Text("\($0) h").tag($0) }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("When a tunnel counts as Fair or Poor").font(.callout.weight(.medium))
                    Text("Judged on the typical (median) latency and the share of probes lost, over the last 5 minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("")
                            Text("Fair from").font(.caption).foregroundStyle(.secondary)
                            Text("Poor from").font(.caption).foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Latency (ms)")
                            TextField("", value: $draft.thresholds.fairPingMs, format: .number).frame(width: 70)
                            TextField("", value: $draft.thresholds.poorPingMs, format: .number).frame(width: 70)
                        }
                        GridRow {
                            Text("Packet loss (%)")
                            TextField("", value: $draft.thresholds.fairLossPercent, format: .number).frame(width: 70)
                            TextField("", value: $draft.thresholds.poorLossPercent, format: .number).frame(width: 70)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button("Reset limits to 60 / 150 ms and 1 / 3 %") { draft.thresholds = .standard }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .disabled(!draft.enabled)
            .opacity(draft.enabled ? 1 : 0.5)

            Card {
                VStack(alignment: .leading, spacing: 4) {
                    PaneSectionHeader(title: "What this will do")
                    if draft.enabled {
                        Text("Quality (Good / Fair / Poor), latency, “95% under” and packet loss will appear for connected tunnels, measured against \(activeTunnelNote) every \(draft.intervalSeconds) s.")
                        Text("About \(plan.probesPerDay.formatted()) probes a day per tunnel, roughly \(Format.bytes(plan.trafficPerDayBytes)) of traffic, and up to \(Format.bytes(plan.memoryBytesPerTunnel)) of memory per tunnel. These are estimates (≈\(ProbePlan.bytesPerProbe) bytes per probe, ≈\(ProbePlan.bytesPerStoredSample) per stored sample).")
                            .foregroundStyle(.secondary)
                        Text("History is kept in memory only and is cleared when the app quits. It is not a prediction of future performance.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Quality will show “Not measured”. Speed, data used and last handshake keep working.")
                    }
                }
                .font(.callout)
            }

            if let message = draft.validationMessage {
                Notice(tone: .bad, title: "Cannot apply yet", message: message)
            }
            HStack {
                Button("Apply") {
                    if monitor.apply(draft) == nil { justApplied = true }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.validationMessage != nil || draft == monitor.settings)
                Button("Revert") { draft = monitor.settings; justApplied = false }
                    .disabled(draft == monitor.settings)
                if justApplied && draft == monitor.settings {
                    Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            draft = monitor.settings
            loaded = true
        }
        .onChange(of: draft) { _, _ in justApplied = false }
    }
}
