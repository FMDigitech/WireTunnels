import Charts
import SwiftUI

// Shared look for the monitoring UI: brand purple for selection and primary actions, green /
// amber / red only for state. State is always said with a word and an icon, never colour alone.

enum StatusTone {
    case good, warn, bad, info, neutral

    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .info: return .accentColor
        case .neutral: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        case .neutral: return "circle"
        }
    }
}

extension QualityLevel {
    var tone: StatusTone {
        switch self {
        case .good: return .good
        case .fair: return .warn
        case .poor: return .bad
        case .unmeasured: return .neutral
        }
    }
}

/// Small rounded label: icon + word + tinted background.
struct StatusPill: View {
    let text: String
    var tone: StatusTone = .neutral
    var showsIcon = true

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon { Image(systemName: tone.icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tone.color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct QualityBadge: View {
    let level: QualityLevel

    var body: some View {
        if level == .unmeasured {
            Text("—").foregroundStyle(.tertiary).accessibilityLabel("Quality not measured")
        } else {
            StatusPill(text: level.rawValue, tone: level.tone)
        }
    }
}

/// A rounded panel on the window background.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    /// No background or border, for content that already sits inside a `FloatingPanel`.
    var plain = false
    @ViewBuilder var content: Content

    var body: some View {
        if plain {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        }
    }
}

/// Section title with an optional one-line explanation, used inside detail panes.
struct PaneSectionHeader: View {
    let title: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// The one-sentence state of a whole screen, with optional figures on the right.
struct SummaryBanner<Trailing: View>: View {
    let tone: StatusTone
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: tone.icon)
                    .font(.title2)
                    .foregroundStyle(tone.color)
                    .frame(width: 42, height: 42)
                    .background(tone.color.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                trailing
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension SummaryBanner where Trailing == EmptyView {
    init(tone: StatusTone, title: String, detail: String? = nil) {
        self.init(tone: tone, title: title, detail: detail) { EmptyView() }
    }
}

/// "↓ 92.5 Mbps ↑ 19.3 Mbps" with a caption saying what was summed.
struct SpeedFigures: View {
    let caption: String
    let downMbps: Double?
    let upMbps: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(Format.mbps(downMbps), systemImage: "arrow.down")
                Label(Format.mbps(upMbps), systemImage: "arrow.up")
            }
            .font(.title3.weight(.semibold).monospacedDigit())
            .labelStyle(.titleAndIcon)
        }
    }
}

/// A labelled figure. `—` when there is no value, never a made-up zero.
struct Metric: View {
    let label: String
    let value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            if let note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Label on the left, value on the right; both selectable.
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(monospaced ? .system(.body, design: .monospaced) : .body).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// Notice with an icon and a word, for errors, warnings and explanations.
struct Notice: View {
    let tone: StatusTone
    let title: String
    var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.icon).foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Layout

/// A white (surface) panel with a thin border and 12 pt corners that floats on the grey page.
struct FloatingPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

private struct MasterIsCompactKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when the list pane is narrow, so lists can drop optional columns instead of truncating names.
    var masterIsCompact: Bool {
        get { self[MasterIsCompactKey.self] }
        set { self[MasterIsCompactKey.self] = newValue }
    }
}

/// List on the left, details on the right, both as floating panels. Widths are computed from the
/// space given (never from the content), so selecting something cannot make the panes jump or clip.
/// When there is no room for both side by side they stack, list above details.
struct MasterDetail<Master: View, Detail: View>: View {
    var masterFraction: CGFloat = 0.46
    var masterMin: CGFloat = 360
    var masterMax: CGFloat = 600
    var detailMin: CGFloat = 300
    /// Margin around the panels; 0 when the screen already pads its content.
    var inset: CGFloat = 16
    @ViewBuilder var master: Master
    @ViewBuilder var detail: Detail

    private let gap: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            if total >= masterMin + detailMin + gap {
                let masterWidth = min(max(total * masterFraction, masterMin), min(masterMax, total - detailMin - gap))
                HStack(spacing: gap) {
                    FloatingPanel { master.environment(\.masterIsCompact, masterWidth < 520) }
                        .frame(width: masterWidth)
                    FloatingPanel { detail }
                }
            } else {
                VStack(spacing: gap) {
                    FloatingPanel { master.environment(\.masterIsCompact, true) }
                        .frame(height: max(180, geo.size.height * 0.4))
                    FloatingPanel { detail }
                }
            }
        }
        .padding(inset)
    }
}

/// Plain text tabs with an underline on the selected one. Scrolls sideways instead of forcing a
/// minimum width, which a segmented control with many labels would.
struct TabStrip<Tab: Hashable & Identifiable & RawRepresentable>: View where Tab.RawValue == String {
    let tabs: [Tab]
    @Binding var selection: Tab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(tabs) { tab in
                    Button { selection = tab } label: {
                        Text(tab.rawValue)
                            .font(.callout.weight(selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(selection == tab ? Color.accentColor : .clear).frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension View {
    /// Fixed sheet size, but never taller than the visible screen minus room for the title bar and
    /// the Dock, so a tall form stays reachable on a small MacBook (its content already scrolls).
    func sheetFrame(width: CGFloat, height: CGFloat) -> some View {
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 100
        return frame(width: width, height: min(height, max(room, 480)))
    }
}

/// Lays children out left to right and wraps to a new line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        var origins: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

/// Figures in a grid that wraps to the width available instead of demanding a minimum.
struct MetricGrid<Content: View>: View {
    var minimum: CGFloat = 130
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), alignment: .topLeading)],
                  alignment: .leading, spacing: 12) {
            content
        }
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case minutes15 = "15 min", hour1 = "1 h", hours24 = "24 h"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .minutes15: return 900
        case .hour1: return 3_600
        case .hours24: return 86_400
        }
    }
}

struct RangePicker: View {
    @Binding var range: ChartRange

    var body: some View {
        Picker("Range", selection: $range) {
            ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Download (cyan) and upload (purple) over the chosen period, with a legend and the latest value.
struct SpeedChart: View {
    let points: [TrafficPoint]
    let range: ChartRange
    var markers: [Date] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if points.count < 2 {
                Text("Collecting data… the chart appears after a few samples.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value("Time", p.time), y: .value("Mbps", p.rxMbps), series: .value("Series", "Download"))
                            .foregroundStyle(by: .value("Series", "Download"))
                        LineMark(x: .value("Time", p.time), y: .value("Mbps", p.txMbps), series: .value("Series", "Upload"))
                            .foregroundStyle(by: .value("Series", "Upload"))
                    }
                    ForEach(markers, id: \.self) { RuleMark(x: .value("Event", $0)).foregroundStyle(.secondary.opacity(0.4)) }
                }
                .chartForegroundStyleScale(["Download": Color.cyan, "Upload": Color.accentColor])
                .chartXScale(domain: Date().addingTimeInterval(-range.seconds)...Date())
                .chartYAxisLabel("Mbps")
                .frame(height: 150)
                if let last = points.last {
                    Text("Latest: ↓ \(Format.mbps(last.rxMbps))  ↑ \(Format.mbps(last.txMbps))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Latency (ping) over time; a missing reply is shown as a red tick, not as zero.
struct LatencyChart: View {
    let samples: [ProbeSample]
    let range: ChartRange

    var body: some View {
        let replies = samples.filter { $0.latencyMs != nil }
        let lost = samples.filter { $0.latencyMs == nil }
        if samples.count < 2 {
            Text("Collecting data… the chart appears after a few probes.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
        } else {
            Chart {
                ForEach(replies, id: \.time) { s in
                    LineMark(x: .value("Time", s.time), y: .value("ms", s.latencyMs ?? 0))
                        .foregroundStyle(Color.accentColor)
                }
                ForEach(lost, id: \.time) { s in
                    PointMark(x: .value("Time", s.time), y: .value("ms", 0))
                        .symbol(.cross).foregroundStyle(.red)
                }
            }
            .chartXScale(domain: Date().addingTimeInterval(-range.seconds)...Date())
            .chartYAxisLabel("ms")
            .frame(height: 130)
            Text("Red crosses are probes without a reply.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

enum Format {
    static func mbps(_ value: Double?) -> String {
        guard let value else { return "—" }
        return RateFormat.text(mbps: value)
    }

    static func duration(since date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s) s" }
        if s < 3_600 { return "\(s / 60)m" }
        return "\(s / 3_600)h \((s % 3_600) / 60)m"
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        return "\(duration(since: date, now: now)) ago"
    }

    static func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// Empty or "nothing here yet" state with an icon, a title and a hint.
struct EmptyPane: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
