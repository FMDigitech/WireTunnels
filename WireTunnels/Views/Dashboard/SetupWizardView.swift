import SwiftUI

// MARK: - SetupWizardView

struct SetupWizardView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @State private var isInstallingTools = false

    private var helperReady: Bool {
        !tunnelManager.helperRequiresApproval && tunnelManager.environment.helperInstalled
    }

    private var toolsReady: Bool {
        !tunnelManager.toolInstallRequired && tunnelManager.environment.isReady
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            if !tunnelManager.isInitialized {
                loadingPhase
            } else {
                setupPhase
            }
        }
        .task(id: tunnelManager.needsSetup) {
            guard tunnelManager.needsSetup else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                guard !tunnelManager.isLoading else { continue }
                await tunnelManager.refreshHelperRegistrationStatus()
            }
        }
    }

    // MARK: - Loading Phase

    private var loadingPhase: some View {
        VStack(spacing: 20) {
            appIcon
            ProgressView()
                .controlSize(.large)
            Text(tunnelManager.setupStatus ?? "Starting up…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Setup Phase

    private var setupPhase: some View {
        VStack(spacing: 32) {
            VStack(spacing: 10) {
                appIcon
                Text("Quick Setup Required")
                    .font(.title.bold())
                Text("WireTunnels needs a privileged helper to manage WireGuard interfaces securely.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            VStack(spacing: 12) {
                SetupStepRow(
                    number: 1,
                    title: "Enable Privileged Helper",
                    description: "Required to manage network interfaces. macOS will ask for confirmation.",
                    isComplete: helperReady,
                    isActive: !helperReady,
                    isLoading: tunnelManager.isLoading && !helperReady,
                    actionLabel: "Enable in System Settings",
                    actionIcon: "gear"
                ) {
                    tunnelManager.openHelperApprovalSettings()
                }

                SetupStepRow(
                    number: 2,
                    title: "Install WireGuard Tools",
                    description: "Verified binaries bundled with the app. No download required.",
                    isComplete: toolsReady,
                    isActive: helperReady && !toolsReady,
                    isLoading: isInstallingTools || (tunnelManager.isLoading && helperReady && !toolsReady),
                    actionLabel: "Install Tools",
                    actionIcon: "shippingbox.and.arrow.backward",
                    statusMessage: (helperReady && !toolsReady) ? tunnelManager.setupStatus : nil,
                    errorMessage: (helperReady && !toolsReady) ? tunnelManager.errorMessage : nil
                ) {
                    installTools()
                }
                .disabled(tunnelManager.bundledRuntimeStatus?.isValid != true)
            }
            .frame(maxWidth: 500)
        }
        .padding(48)
    }

    private var appIcon: some View {
        Image(systemName: "network.badge.shield.half.filled")
            .font(.system(size: 52))
            .foregroundStyle(.tint)
    }

    // MARK: - Actions

    private func installTools() {
        guard !isInstallingTools && !tunnelManager.isLoading else { return }
        isInstallingTools = true
        Task { @MainActor in
            await tunnelManager.installBundledTools()
            isInstallingTools = false
        }
    }
}

// MARK: - SetupStepRow

private struct SetupStepRow: View {
    let number: Int
    let title: String
    let description: String
    let isComplete: Bool
    let isActive: Bool
    var isLoading: Bool = false
    let actionLabel: String
    let actionIcon: String
    var statusMessage: String? = nil
    var errorMessage: String? = nil
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(circleColor)
                    .frame(width: 36, height: 36)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.headline.bold())
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(isActive || isComplete ? .primary : .secondary)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isActive && !isComplete {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(statusMessage ?? "Working…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    } else {
                        Button(action: action) {
                            Label(actionLabel, systemImage: actionIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 2)

                        if let msg = errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .opacity(isActive || isComplete ? 1.0 : 0.45)
    }

    private var circleColor: Color {
        if isComplete { return .green }
        if isActive { return .accentColor }
        return Color.secondary.opacity(0.3)
    }
}
