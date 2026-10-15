import AppKit
import SwiftUI

@MainActor
final class RuleFields: ObservableObject {
    @Published var enabled = false
    @Published var interface: AutoConnectInterface = .wifi
    @Published var anyWiFi = true
    @Published var ssids: [String] = []
    @Published var newSSID = ""
    var saves = 0
}

private struct RuleHost: View {
    @ObservedObject var fields: RuleFields
    var body: some View {
        OnDemandMatchSection(
            title: "Disconnect", systemImage: "bolt.slash.fill",
            enabled: $fields.enabled, interface: $fields.interface,
            anyWiFi: $fields.anyWiFi, ssids: $fields.ssids, newSSID: $fields.newSSID,
            knownNetworks: [], currentSSID: nil, canEdit: true,
            hasWiFiNamePermission: true, onRequestWiFiPermission: {},
            onOpenLocationSettings: {}, onSave: { fields.saves += 1 }
        )
    }
}

@main
struct OnDemandEditorTests {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fields = RuleFields()
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RuleHost(fields: fields))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 150_000_000)
        // Loading a saved rule is a model change, not a user's toggle action.
        fields.enabled = true
        fields.interface = .both
        fields.anyWiFi = false
        fields.ssids = ["Synthetic trusted network"]
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fields.saves == 0 else { fatalError("Opening details saved On-Demand rules and could disconnect an active tunnel") }
        fields.anyWiFi = true
        fields.ssids = []
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fields.saves == 0 else { fatalError("Reloading a confirmed rule wrote it back through the UI") }
        func switches(in view: NSView) -> [NSSwitch] {
            (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
        }
        guard let control = window.contentView.flatMap({ switches(in: $0).first }) else {
            fatalError("The test could not find the On-Demand switch")
        }
        control.performClick(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fields.saves == 1, !fields.enabled else { fatalError("A user's toggle no longer saved the rule") }
        print("PASS: loading On-Demand fields never saves rules or requests connection changes")
    }
}
