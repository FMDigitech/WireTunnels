import SwiftUI

// NOTE: WireGuardTemplate is defined here. If it is also defined elsewhere in the project,
// remove this definition and import from the shared location.
enum WireGuardTemplate: String, CaseIterable, Identifiable {
    case empty = "Empty"
    case splitTunnel = "Split Tunnel"
    case fullTunnel = "Full Tunnel"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .empty:       return "doc"
        case .splitTunnel: return "arrow.triangle.branch"
        case .fullTunnel:  return "shield.fill"
        }
    }

    var description: String {
        switch self {
        case .empty:
            return "Blank config with all required sections."
        case .splitTunnel:
            return "Routes only specific subnets through the VPN."
        case .fullTunnel:
            return "Routes all traffic (0.0.0.0/0) through the VPN."
        }
    }

    var content: String {
        switch self {
        case .empty:
            return """
[Interface]
PrivateKey =
Address =
DNS =

[Peer]
PublicKey =
Endpoint =
AllowedIPs =
PersistentKeepalive = 25
"""
        case .splitTunnel:
            return """
[Interface]
PrivateKey = <PRIVATE_KEY>
Address = 10.8.0.2/24
DNS = 10.8.0.1

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.8.0.0/24, 192.168.0.0/24
PersistentKeepalive = 25
"""
        case .fullTunnel:
            return """
[Interface]
PrivateKey = <PRIVATE_KEY>
Address = 10.8.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
"""
        }
    }
}

// MARK: - Template Picker View

struct TemplatePickerView: View {
    @Binding var content: String
    @Environment(\.dismiss) var dismiss
    @State private var hoveredTemplate: WireGuardTemplate? = nil
    @State private var confirmingTemplate: WireGuardTemplate? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insert Template")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            Divider()
                .padding(.vertical, 4)

            ForEach(WireGuardTemplate.allCases) { template in
                TemplateRow(template: template, isHovered: hoveredTemplate == template) {
                    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        applyTemplate(template)
                    } else {
                        confirmingTemplate = template
                    }
                }
                .onHover { hovered in
                    hoveredTemplate = hovered ? template : nil
                }
            }
        }
        .frame(minWidth: 280)
        .confirmationDialog(
            "Replace Current Content?",
            isPresented: .init(
                get: { confirmingTemplate != nil },
                set: { if !$0 { confirmingTemplate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace") {
                if let template = confirmingTemplate {
                    applyTemplate(template)
                }
                confirmingTemplate = nil
            }
            Button("Cancel", role: .cancel) {
                confirmingTemplate = nil
            }
        } message: {
            Text("This will replace your current config with the \"\(confirmingTemplate?.rawValue ?? "")\" template.")
        }
    }

    private func applyTemplate(_ template: WireGuardTemplate) {
        content = template.content
        dismiss()
    }
}

// MARK: - Template Row

private struct TemplateRow: View {
    let template: WireGuardTemplate
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: template.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.rawValue)
                        .font(.body.weight(.medium))
                    Text(template.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
