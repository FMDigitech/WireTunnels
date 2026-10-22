import AppKit
import SwiftUI

@MainActor
final class RuleFields: ObservableObject {
    @Published var enabled = false
    @Published var interface: AutoConnectInterface = .wifi
    @Published var anyWiFi = true
    @Published var ssids: [String] = []
    @Published var newSSID = ""
    @Published var anyEthernet = true
    @Published var ethernetSubnets: [String] = []
    @Published var newEthernetSubnet = ""
    var saves = 0
    var permissionRequests = 0
}

private struct RuleHost: View {
    @ObservedObject var fields: RuleFields
    var body: some View {
        OnDemandMatchSection(
            title: "Disconnect", systemImage: "bolt.slash.fill",
            enabled: $fields.enabled, interface: $fields.interface,
            anyWiFi: $fields.anyWiFi, ssids: $fields.ssids, newSSID: $fields.newSSID,
            anyEthernet: $fields.anyEthernet, ethernetSubnets: $fields.ethernetSubnets,
            newEthernetSubnet: $fields.newEthernetSubnet,
            knownNetworks: [], currentSSID: nil,
            currentEthernetAddresses: ["192.168.10.45"], canEdit: true,
            hasWiFiNamePermission: true, onRequestWiFiPermission: { fields.permissionRequests += 1 },
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
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 1000),
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
        fields.anyEthernet = false
        fields.ethernetSubnets = ["192.168.10.0/24", "fd00::/64"]
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fields.saves == 0 else { fatalError("Opening details saved On-Demand rules and could disconnect an active tunnel") }
        fields.anyWiFi = true
        fields.ssids = []
        fields.anyEthernet = true
        fields.ethernetSubnets = []
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

        // Submit CIDRs through the real text field's AppKit action.
        fields.enabled = true
        fields.interface = .ethernet
        fields.anyWiFi = false
        fields.ssids = ["Synthetic Wi-Fi filter"]
        fields.anyEthernet = false
        fields.saves = 0
        try await Task.sleep(nanoseconds: 150_000_000)
        func textFields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
        }
        guard let entry = window.contentView.flatMap({ textFields(in: $0).first {
            $0.placeholderString == "192.168.10.0/24 or fd00::/64"
        } }), let action = entry.action else {
            fatalError("The test could not find the Ethernet subnet text field action")
        }
        func submit() {
            NSApplication.shared.sendAction(action, to: entry.target, from: entry)
        }
        fields.newEthernetSubnet = "192.168.10.0/99"
        try await Task.sleep(nanoseconds: 150_000_000)
        submit()
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fields.saves == 0, fields.ethernetSubnets.isEmpty else {
            fatalError("Submitting invalid Ethernet CIDR input persisted a rule")
        }
        fields.newEthernetSubnet = " 192.168.10.45/24 "
        try await Task.sleep(nanoseconds: 150_000_000)
        submit()
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fields.ethernetSubnets == ["192.168.10.0/24"], fields.newEthernetSubnet.isEmpty, fields.saves == 1 else {
            fatalError("Adding a subnet must normalize its host bits and save exactly once")
        }
        fields.newEthernetSubnet = "192.168.10.200/24"
        try await Task.sleep(nanoseconds: 150_000_000)
        submit()
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fields.ethernetSubnets == ["192.168.10.0/24"], fields.saves == 1 else {
            fatalError("Equivalent Ethernet subnet input added a duplicate")
        }
        fields.newEthernetSubnet = "fd00::1234/64"
        try await Task.sleep(nanoseconds: 150_000_000)
        submit()
        try await Task.sleep(nanoseconds: 150_000_000)
        guard fields.ethernetSubnets == ["192.168.10.0/24", "fd00::/64"], fields.saves == 2 else {
            fatalError("Adding an IPv6 subnet must normalize and save exactly once")
        }
        guard fields.ssids == ["Synthetic Wi-Fi filter"], !fields.anyWiFi, fields.permissionRequests == 0 else {
            fatalError("Editing Ethernet subnets changed Wi-Fi filters or requested Location access")
        }
        print("PASS: loading On-Demand fields never saves; Ethernet submissions validate, normalize and save once")
    }
}
