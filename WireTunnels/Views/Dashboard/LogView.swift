import Charts
import SwiftUI

/// A parsed `[date time] [LEVEL] message` line from LogService.
private struct ParsedLogLine: Identifiable {
    let id: Int
    let time: Date
    let level: LogLevel
    let message: String
    let raw: String
    let source: String

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let pattern = try? NSRegularExpression(pattern: #"^\[(.+?)\] \[(INFO|WARN|ERROR)\] (.*)$"#)

    init?(entry: LogEntry, tunnelNames: [String]) {
        let line = entry.line
        let range = NSRange(line.startIndex..., in: line)
        guard let match = Self.pattern?.firstMatch(in: line, range: range),
              let dateRange = Range(match.range(at: 1), in: line),
              let levelRange = Range(match.range(at: 2), in: line),
              let messageRange = Range(match.range(at: 3), in: line),
              let date = Self.formatter.date(from: String(line[dateRange])),
              let level = LogLevel(rawValue: String(line[levelRange])) else { return nil }
        id = entry.id
        time = date
        self.level = level
        let text = String(line[messageRange])
        message = text
        raw = line
        let lower = text.lowercased()
        if tunnelNames.contains(where: { text.contains($0) }) { source = "Tunnels" }
        else if lower.contains("network") || lower.contains("dns") || lower.contains("profile") || lower.contains("wi-fi") { source = "Network" }
        else if lower.contains("helper") || lower.contains("wg ") || lower.contains("wireguard") { source = "Helper" }
        else { source = "App" }
    }

    var tone: StatusTone {
        switch level {
        case .info: return .neutral
        case .warning: return .warn
        case .error: return .bad
        }
    }

    var levelText: String { level == .warning ? "WARN" : level.rawValue }
}

struct LogView: View {
    @ObservedObject var logService: LogService = .shared
    @EnvironmentObject var tunnelManager: TunnelManager

    private enum Window: String, CaseIterable, Identifiable {
        case min15 = "Last 15 min", hour1 = "Last hour", hours24 = "Last 24 h", all = "All"
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .min15: return 900
            case .hour1: return 3_600
            case .hours24: return 86_400
            case .all: return nil
            }
        }
    }

    @State private var search = ""
    @State private var level = "All levels"
    @State private var window: Window = .min15
    @State private var source = "All sources"
    @State private var selectedID: Int?
    @State private var confirmClear = false

    private var parsed: [ParsedLogLine] {
        let names = tunnelManager.tunnels.map(\.name)
        return logService.logEntries.compactMap { ParsedLogLine(entry: $0, tunnelNames: names) }
    }

    private var windowed: [ParsedLogLine] {
        guard let seconds = window.seconds else { return parsed }
        let cutoff = Date().addingTimeInterval(-seconds)
        return parsed.filter { $0.time >= cutoff }
    }

    private var visible: [ParsedLogLine] {
        windowed.filter { line in
            (search.isEmpty || line.message.localizedCaseInsensitiveContains(search))
            && (level == "All levels" || line.levelText == level)
            && (source == "All sources" || line.source == source)
        }.reversed()
    }

    private var buckets: [(minute: Date, worst: LogLevel, count: Int)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: windowed) { calendar.dateInterval(of: .minute, for: $0.time)?.start ?? $0.time }
        return grouped.map { minute, lines in
            let worst: LogLevel = lines.contains { $0.level == .error } ? .error : (lines.contains { $0.level == .warning } ? .warning : .info)
            return (minute, worst, lines.count)
        }.sorted { $0.minute < $1.minute }
    }

    var body: some View {
        let lines = windowed
        let warns = lines.filter { $0.level == .warning }.count
        let errors = lines.filter { $0.level == .error }.count
        VStack(alignment: .leading, spacing: 12) {
            Text("What the app did and when. Nearby lines show what happened around the same time, which is context, not proof of a cause.")
                .font(.callout).foregroundStyle(.secondary)
            SummaryBanner(tone: errors > 0 ? .bad : (warns > 0 ? .warn : .good),
                          title: errors > 0 ? "\(errors) \(errors == 1 ? "error" : "errors") in \(window.rawValue.lowercased())"
                              : (warns > 0 ? "\(warns) \(warns == 1 ? "warning" : "warnings") in \(window.rawValue.lowercased())" : "No warnings or errors"),
                          detail: lines.last.map { "Latest: \($0.message)" }) {
                HStack(spacing: 8) {
                    StatusPill(text: "\(lines.count - warns - errors) info", tone: .neutral, showsIcon: false)
                    StatusPill(text: "\(warns) warn", tone: warns > 0 ? .warn : .neutral, showsIcon: false)
                    StatusPill(text: "\(errors) error", tone: errors > 0 ? .bad : .neutral, showsIcon: false)
                }
            }
            MasterDetail(masterFraction: 0.58, masterMin: 400, masterMax: 760, detailMin: 280, inset: 0) {
                listPane
            } detail: {
                detailPane
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Log")
        .confirmationDialog("Clear the log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { logService.clearLog() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every entry and also deletes the log file on disk. It cannot be undone.")
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search the log", text: $search).textFieldStyle(.roundedBorder)
                Picker("Level", selection: $level) {
                    ForEach(["All levels", "INFO", "WARN", "ERROR"], id: \.self) { Text($0) }
                }.labelsHidden().fixedSize()
            }.padding(8)
            HStack(spacing: 8) {
                Picker("Range", selection: $window) { ForEach(Window.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize()
                Picker("Source", selection: $source) {
                    ForEach(["All sources", "Tunnels", "Network", "Helper", "App"], id: \.self) { Text($0) }
                }.labelsHidden().fixedSize()
                Spacer()
                Button("Copy \(visible.count)") { copy(visible.reversed()) }
                    .help("Copy the lines that match the filters")
                    .disabled(visible.isEmpty)
                Button("Clear…") { confirmClear = true }
                    .disabled(parsed.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 8).padding(.bottom, 8)

            if !buckets.isEmpty {
                Chart(buckets, id: \.minute) { bucket in
                    BarMark(x: .value("Minute", bucket.minute, unit: .minute), y: .value("Lines", bucket.count))
                        .foregroundStyle(bucket.worst == .error ? Color.red : (bucket.worst == .warning ? Color.orange : Color.secondary.opacity(0.5)))
                }
                .chartYAxis(.hidden)
                .frame(height: 44)
                .padding(.horizontal, 8)
                .accessibilityLabel("Lines per minute; orange bars contain warnings, red bars contain errors")
            }
            Divider()
            HStack {
                Text("Time").frame(width: 78, alignment: .leading)
                Text("Level").frame(width: 56, alignment: .leading)
                Text("Message")
                Spacer()
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 4)
            if visible.isEmpty {
                EmptyPane(icon: "doc.text.magnifyingglass",
                          title: parsed.isEmpty ? "No log entries" : "No line matches",
                          message: parsed.isEmpty ? "Activity will appear here as you use the app."
                              : "Search: \(search.isEmpty ? "none" : "“\(search)”") · \(level) · \(window.rawValue) · \(source)")
                if !parsed.isEmpty {
                    Button("Clear filters") { search = ""; level = "All levels"; window = .all; source = "All sources" }
                        .padding(.bottom, 12)
                }
            } else {
                List(visible, selection: $selectedID) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.clock(line.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        StatusPill(text: line.levelText, tone: line.tone, showsIcon: false).frame(width: 56, alignment: .leading)
                        Text(line.message).font(.callout).lineLimit(3)
                    }
                    .tag(line.id)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let line = parsed.first(where: { $0.id == selectedID }), let index = parsed.firstIndex(where: { $0.id == line.id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    StatusPill(text: line.levelText, tone: line.tone)
                    Text(line.message).font(.headline).textSelection(.enabled)
                    Text("\(line.time.formatted(date: .abbreviated, time: .standard)) · \(line.source)")
                        .font(.caption).foregroundStyle(.secondary)
                    PaneSectionHeader(title: "Around this line", note: "Context only: lines close in time are not necessarily related.")
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(parsed[max(0, index - 3)...min(parsed.count - 1, index + 3)]) { near in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(Format.clock(near.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(near.message).font(.caption).fontWeight(near.id == line.id ? .bold : .regular)
                                }
                            }
                        }
                    }
                    Button("Copy this line") { copy([line]) }
                    if line.level != .info {
                        Text("Next: open Network Doctor to scan this Mac, or the tunnel's Overview for its events.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyPane(icon: "text.cursor", title: "Select a line",
                      message: "You will see the lines around it, and where to go next. Use the bars to see which minutes had warnings or errors.")
        }
    }

    private func copy(_ lines: [ParsedLogLine]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map(\.raw).joined(separator: "\n"), forType: .string)
    }
}
