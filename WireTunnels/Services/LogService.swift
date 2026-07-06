import Foundation
import Combine

struct LogEntry: Identifiable {
    let id: Int
    let line: String
}

enum LogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

@MainActor
final class LogService: ObservableObject {
    static let shared = LogService()
    static let showRawOutputPreferenceKey = "showRawOutput"

    @Published var logEntries: [LogEntry] = []
    private var nextID = 0

    var logLines: [String] { logEntries.map(\.line) }

    private let logFile: URL
    private let defaults: UserDefaults
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(
        logFile: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.logFile = logFile ?? AppPaths.logFile
        self.defaults = defaults
        createLogDirectoryIfNeeded()
    }

    func info(_ message: String) {
        log(message, level: .info)
    }

    func warning(_ message: String) {
        log(message, level: .warning)
    }

    func error(_ message: String) {
        log(message, level: .error)
    }

    func rawOutput(_ message: String, level: LogLevel = .info) {
        guard defaults.bool(forKey: Self.showRawOutputPreferenceKey) else { return }
        log(message, level: level)
    }

    func clearLog() {
        logEntries.removeAll()
        nextID = 0
        try? FileManager.default.removeItem(at: logFile)
    }

    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)"
        print(line)
        nextID += 1
        logEntries.append(LogEntry(id: nextID, line: line))
        if logEntries.count > 1000 { logEntries.removeFirst() }
        appendToFile(line)
    }

    private func createLogDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func appendToFile(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            createLogDirectoryIfNeeded()
            try? data.write(to: logFile)
        }
    }
}
