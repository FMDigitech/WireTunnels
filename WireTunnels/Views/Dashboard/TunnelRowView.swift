import SwiftUI

struct TunnelRowView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    let tunnel: Tunnel
    @State private var isProcessing = false

    private var hasWarning: Bool {
        tunnelManager.activeWarnings.contains { warning in
            switch warning {
            case .multipleFullTunnels(let names):       return names.contains(tunnel.name)
            case .fullTunnelActive(let name):           return name == tunnel.name
            case .overlappingAllowedIPs(let a, let b):  return a == tunnel.name || b == tunnel.name
            case .conflictingDNS(let names):            return names.contains(tunnel.name)
            }
        }
    }

    private var statusColor: Color {
        if hasWarning { return .yellow }
        return tunnel.isActive ? .green : .secondary
    }

    private var statusLabel: String {
        if hasWarning { return "Warning" }
        return tunnel.isActive ? "Connected" : "Disconnected"
    }

    private var connectionBinding: Binding<Bool> {
        Binding(
            get: { tunnel.isActive },
            set: { shouldConnect in
                guard shouldConnect != tunnel.isActive, !isProcessing else { return }
                isProcessing = true
                Task {
                    if shouldConnect {
                        await tunnelManager.connectTunnel(tunnel)
                    } else {
                        await tunnelManager.disconnectTunnel(tunnel)
                    }
                    isProcessing = false
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }
            .accessibilityLabel(statusLabel)

            // Tunnel info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tunnel.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if tunnel.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }

                    if hasWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                if let endpoint = tunnel.endpoint, !endpoint.isEmpty {
                    Text(endpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !tunnel.allowedIPs.isEmpty {
                    Text(tunnel.allowedIPs.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                // Favorite toggle
                Button {
                    tunnelManager.toggleFavorite(tunnel)
                } label: {
                    Image(systemName: tunnel.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(tunnel.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(tunnel.isFavorite ? "Remove from favorites" : "Add to favorites")

                Toggle(isOn: connectionBinding) {
                    Text("Connection")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isProcessing)
                .controlSize(.small)
                .accessibilityLabel("Connection for \(tunnel.name)")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
