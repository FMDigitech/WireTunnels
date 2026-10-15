import SwiftUI

/// Editor for one half (connect or disconnect) of an on-demand rule. Two of these
/// are shown side by side in TunnelDetailView so the connect and disconnect
/// network lists can be configured independently.
struct OnDemandMatchSection: View {
    let title: String
    let systemImage: String
    @Binding var enabled: Bool
    @Binding var interface: AutoConnectInterface
    @Binding var anyWiFi: Bool
    @Binding var ssids: [String]
    @Binding var newSSID: String
    let knownNetworks: [String]
    let currentSSID: String?
    let canEdit: Bool
    let hasWiFiNamePermission: Bool
    let onRequestWiFiPermission: () -> Void
    let onOpenLocationSettings: () -> Void
    let onSave: () -> Void

    private var showWiFiOptions: Bool {
        enabled && (interface == .wifi || interface == .both)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { enabled = $0; onSave() }
            )) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)
            .disabled(!canEdit)

            if enabled {
                HStack {
                    Text("\(title) on")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)

                    Picker("", selection: Binding(
                        get: { interface },
                        set: { interface = $0; onSave() }
                    )) {
                        ForEach(AutoConnectInterface.allCases, id: \.self) { iface in
                            Text(iface.displayName).tag(iface)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!canEdit)
                }

                if showWiFiOptions {
                    Toggle("Any Wi-Fi Network", isOn: Binding(
                        get: { anyWiFi },
                        set: { isAny in
                            anyWiFi = isAny
                            if isAny {
                                ssids = []
                                onSave()
                            } else {
                                // Wait for an SSID before persisting a specific-network rule.
                                onRequestWiFiPermission()
                            }
                        }
                    ))
                        .toggleStyle(.checkbox)
                        .disabled(!canEdit)

                    if !anyWiFi {
                        if !hasWiFiNamePermission {
                            wifiPermissionWarning
                        }

                        // SSID list
                        if !ssids.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(ssids, id: \.self) { ssid in
                                    HStack {
                                        Image(systemName: "wifi")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                        Text(ssid)
                                            .font(.system(.subheadline, design: .monospaced))
                                        Spacer()
                                        Button {
                                            ssids.removeAll { $0 == ssid }
                                            onSave()
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!canEdit)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }

                        // Known networks (from System Settings > Wi-Fi)
                        let selectableKnownNetworks = knownNetworks.filter { !ssids.contains($0) }
                        if !selectableKnownNetworks.isEmpty {
                            Menu {
                                ForEach(selectableKnownNetworks, id: \.self) { network in
                                    Button(network) {
                                        ssids.append(network)
                                        onSave()
                                    }
                                }
                            } label: {
                                Label("Add Known Network…", systemImage: "wifi")
                            }
                            .disabled(!canEdit)
                        }

                        // Manual entry - fallback for networks not in the known list above
                        HStack {
                            TextField("Or type SSID manually", text: $newSSID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { addSSID() }
                            Button("Add") { addSSID() }
                                .buttonStyle(.bordered)
                                .disabled(!canEdit ||
                                          newSSID.trimmingCharacters(in: .whitespaces).isEmpty ||
                                          ssids.contains(newSSID.trimmingCharacters(in: .whitespaces)))
                        }

                        // Add current network shortcut
                        if let currentSSID, !ssids.contains(currentSSID) {
                            Button {
                                ssids.append(currentSSID)
                                onSave()
                            } label: {
                                Label("Add Current: \"\(currentSSID)\"", systemImage: "wifi.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!canEdit)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var wifiPermissionWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "WireTunnels needs Location access to read the Wi-Fi network name. Without it, rules for specific networks won't trigger - enable it in System Settings > Privacy & Security > Location Services.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            Button("Open Location Settings") {
                onOpenLocationSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func addSSID() {
        let s = newSSID.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !ssids.contains(s) else { return }
        ssids.append(s)
        newSSID = ""
        onSave()
    }
}
