import SwiftUI
import AppKit

// MARK: - Line number gutter

/// Line numbers beside the text. A line with an error or a warning also gets ✕ or !, so the
/// state is a symbol and a number, never colour alone.
final class LineNumberRuler: NSRulerView {
    var severities: [Int: DiagnosticSeverity] = [:]

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 52
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView, let layout = textView.layoutManager,
              let container = textView.textContainer, let scroll = scrollView else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height
        let text = textView.string as NSString

        func draw(_ number: Int, lineTop: CGFloat) {
            let severity = severities[number]
            let marker = severity == .error ? "✕ " : severity == .warning ? "! " : ""
            let color: NSColor = severity == .error ? .systemRed : severity == .warning ? .systemOrange : .secondaryLabelColor
            let label = "\(marker)\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: lineTop + offset), withAttributes: attributes)
        }

        let visible = scroll.contentView.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        var index = text.length == 0 ? 0 : text.lineRange(for: NSRange(location: layout.characterIndexForGlyph(at: glyphs.location), length: 0)).location
        var number = text.substring(to: index).components(separatedBy: "\n").count
        while index < text.length {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            let top = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: line.location), effectiveRange: nil).minY
            if top + offset > bounds.height { return }
            draw(number, lineTop: top)
            index = NSMaxRange(line)
            number += 1
        }
        // The empty line after a final newline, or the only line of an empty text.
        if text.length == 0 || text.hasSuffix("\n") { draw(number, lineTop: layout.extraLineFragmentRect.minY) }
    }
}

// MARK: - Syntax highlighting NSTextView

struct SyntaxHighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var readOnly: Bool = false
    /// Private and preshared key values are drawn as a grey bar. The text itself is unchanged.
    var hideKeys: Bool = true
    @Binding var revealLine: Int?

    init(text: Binding<String>, readOnly: Bool = false, hideKeys: Bool = true, revealLine: Binding<Int?> = .constant(nil)) {
        _text = text
        self.readOnly = readOnly
        self.hideKeys = hideKeys
        _revealLine = revealLine
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        // TextKit 1: the gutter needs the layout manager's line rectangles.
        let textView = NSTextView(usingTextLayoutManager: false)

        textView.isEditable = !readOnly
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = !readOnly
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        if !readOnly {
            textView.delegate = context.coordinator
        }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.attach(ruler: ruler, to: scrollView)
        context.coordinator.render(textView, text: text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        if !coordinator.isUpdating, textView.string != text || coordinator.renderedHideKeys != hideKeys {
            coordinator.render(textView, text: text)
        }
        if let line = revealLine {
            coordinator.reveal(line: line, in: textView)
            DispatchQueue.main.async { revealLine = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Highlighting

    private static var font: NSFont { .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }

    static func highlighted(_ text: String, reading: ConfigReading, hideKeys: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let kind = i < reading.lines.count ? reading.lines[i] : .blank
            let piece = NSMutableAttributedString(attributedString: highlightLine(line, kind: kind, hideKeys: hideKeys))
            switch reading.severity(onLine: i + 1) {
            case .error?: piece.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.14), range: NSRange(location: 0, length: piece.length))
            case .warning?: piece.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.14), range: NSRange(location: 0, length: piece.length))
            default: break
            }
            result.append(piece)
            if i < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        return result
    }

    private static var baseAttrs: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    private static func highlightLine(_ line: String, kind: ConfigLineKind, hideKeys: Bool) -> NSAttributedString {
        switch kind {
        case .blank:
            return NSAttributedString(string: line, attributes: baseAttrs)
        case .comment:
            return NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.systemGreen])
        case .section:
            let color: NSColor = line.lowercased().contains("interface") ? .systemOrange : .systemTeal
            return NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold), .foregroundColor: color
            ])
        case .invalid:
            return NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.systemRed])
        case .keyValue:
            guard let eq = line.firstIndex(of: "=") else { return NSAttributedString(string: line, attributes: baseAttrs) }
            let keyStr = String(line[line.startIndex..<eq])
            let valStr = String(line[line.index(after: eq)...])
            var valueAttrs = baseAttrs
            if hideKeys, ConfigDiagnostics.secretKeys.contains(keyStr.trimmingCharacters(in: .whitespaces).lowercased()),
               !valStr.trimmingCharacters(in: .whitespaces).isEmpty {
                valueAttrs[.foregroundColor] = NSColor.clear
                valueAttrs[.backgroundColor] = NSColor.tertiaryLabelColor
            }
            let r = NSMutableAttributedString()
            r.append(NSAttributedString(string: keyStr, attributes: [.font: font, .foregroundColor: NSColor.systemBlue]))
            r.append(NSAttributedString(string: "=", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            r.append(NSAttributedString(string: valStr, attributes: valueAttrs))
            return r
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightingTextEditor
        var isUpdating = false
        private(set) var renderedHideKeys = true
        private weak var ruler: LineNumberRuler?
        private var scrollObserver: NSObjectProtocol?

        init(_ parent: SyntaxHighlightingTextEditor) {
            self.parent = parent
        }

        deinit { scrollObserver.map(NotificationCenter.default.removeObserver) }

        func attach(ruler: LineNumberRuler, to scrollView: NSScrollView) {
            self.ruler = ruler
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak ruler] _ in ruler?.needsDisplay = true }
        }

        /// Re-colours the whole text and refreshes the gutter, keeping the caret where it was.
        func render(_ textView: NSTextView, text: String) {
            let reading = ConfigDiagnostics.read(text)
            let sel = textView.selectedRange()
            textView.textStorage?.setAttributedString(
                SyntaxHighlightingTextEditor.highlighted(text, reading: reading, hideKeys: parent.hideKeys))
            let maxLoc = text.utf16.count
            let safeLoc = min(sel.location, maxLoc)
            textView.setSelectedRange(NSRange(location: safeLoc, length: min(sel.length, max(0, maxLoc - safeLoc))))
            renderedHideKeys = parent.hideKeys
            ruler?.severities = Dictionary(uniqueKeysWithValues: Set(reading.diagnostics.map(\.line)).compactMap { line in
                reading.severity(onLine: line).map { (line, $0) }
            })
            ruler?.needsDisplay = true
        }

        func reveal(line: Int, in textView: NSTextView) {
            let text = textView.string as NSString
            var index = 0, current = 1
            while current < line, index < text.length {
                index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
                current += 1
            }
            let range = text.length == 0 ? NSRange(location: 0, length: 0)
                : text.lineRange(for: NSRange(location: min(index, text.length - 1), length: 0))
            let selected = NSRange(location: range.location, length: max(0, range.length - (text.substring(with: range).hasSuffix("\n") ? 1 : 0)))
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(selected)
            textView.scrollRangeToVisible(selected)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, !isUpdating else { return }
            isUpdating = true
            defer { isUpdating = false }
            parent.text = tv.string
            render(tv, text: tv.string)
        }
    }
}

// MARK: - Config Editor View

struct ConfigEditorView: View {
    @Binding var content: String
    var readOnly: Bool = false
    @Binding var revealLine: Int?

    @State private var showTemplatePicker = false
    @State private var showKeys = false

    init(content: Binding<String>, readOnly: Bool = false, revealLine: Binding<Int?> = .constant(nil)) {
        _content = content
        self.readOnly = readOnly
        _revealLine = revealLine
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)

                Text("WireGuard config (.conf)")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    showKeys.toggle()
                } label: {
                    Label(showKeys ? "Hide keys" : "Show keys", systemImage: showKeys ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Private and preshared keys are masked in the editor and hidden in every preview and log")

                if !readOnly {
                    Button {
                        showTemplatePicker = true
                    } label: {
                        Label("Template", systemImage: "square.on.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Insert a template")
                    .popover(isPresented: $showTemplatePicker, arrowEdge: .bottom) {
                        TemplatePickerView(content: $content)
                            .padding(8)
                    }
                }

                if readOnly {
                    Label("Read Only", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Editor area
            ZStack(alignment: .topLeading) {
                SyntaxHighlightingTextEditor(text: $content, readOnly: readOnly, hideKeys: !showKeys, revealLine: $revealLine)

                if !readOnly && content.isEmpty {
                    Text("[Interface]\nPrivateKey = \nAddress = \n\n[Peer]\nPublicKey = \nEndpoint = \nAllowedIPs = ")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 62)
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                        .allowsHitTesting(false)
                }
            }

            Divider()
            statusBar
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var statusBar: some View {
        let reading = ConfigDiagnostics.read(content)
        let errors = reading.errors.count, warnings = reading.warningCount
        return HStack(spacing: 6) {
            Text("\(content.components(separatedBy: .newlines).count) lines · \(content.count) characters")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !readOnly && !content.isEmpty {
                SyntaxBadge(label: "[Interface]", present: !reading.interfaces.isEmpty)
                SyntaxBadge(label: "[Peer]", present: !reading.peers.isEmpty)
                Text("Parse:").font(.caption).foregroundStyle(.secondary)
                if errors > 0 {
                    StatusPill(text: "Needs fixing · \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")", tone: .bad)
                } else if warnings > 0 {
                    StatusPill(text: "Needs attention · \(warnings) warning\(warnings == 1 ? "" : "s")", tone: .warn)
                } else {
                    StatusPill(text: "OK", tone: .good)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Diagnostics list and outline

/// Every problem the reader found, each one a button that jumps to its line.
struct ConfigDiagnosticsList: View {
    let diagnostics: [ConfigDiagnostic]
    var onJump: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Diagnostics").font(.subheadline.weight(.semibold))
                Text("\(diagnostics.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
            if diagnostics.isEmpty {
                Text("No problems found. Valid syntax is not a connection test.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(diagnostics) { item in
                            Button { onJump?(item.line) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    StatusPill(text: Self.label(item.severity), tone: Self.tone(item.severity))
                                        .frame(width: 92, alignment: .leading)
                                    Text("Line \(item.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 52, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.message).font(.callout.weight(.medium))
                                        if !item.hint.isEmpty { Text(item.hint).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(onJump == nil)
                            .accessibilityLabel("\(Self.label(item.severity)), line \(item.line): \(item.message)")
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    static func label(_ severity: DiagnosticSeverity) -> String {
        severity == .error ? "Error" : severity == .warning ? "Warning" : "Note"
    }

    static func tone(_ severity: DiagnosticSeverity) -> StatusTone {
        severity == .error ? .bad : severity == .warning ? .warn : .info
    }
}

/// "What was read": the settings the editor found, with their line and whether they are usable.
struct ConfigOutline: View {
    let reading: ConfigReading

    private enum Need { case required, warns, optional }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Interface", present: !reading.interfaces.isEmpty, reading.interfaces.first,
                    [("privatekey", "PrivateKey", .required), ("address", "Address", .required), ("dns", "DNS", .optional)])
            section("Peer", present: !reading.peers.isEmpty, reading.peers.first,
                    [("publickey", "PublicKey", .required), ("endpoint", "Endpoint", .warns), ("allowedips", "AllowedIPs", .required),
                     ("persistentkeepalive", "PersistentKeepalive", .optional), ("presharedkey", "PresharedKey", .optional)])
        }
    }

    private func section(_ title: String, present: Bool, _ section: ConfigSection?, _ keys: [(String, String, Need)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if !present { Text("(missing)").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(keys, id: \.0) { key, label, need in
                row(label, entry: section?[key], need: need, secret: ConfigDiagnostics.secretKeys.contains(key))
            }
        }
    }

    private func row(_ label: String, entry: ConfigEntry?, need: Need, secret: Bool) -> some View {
        let invalid = entry.map { e in reading.diagnostics.contains { $0.line == e.line && $0.severity == .error } } ?? false
        let tone: StatusTone, word: String
        if let entry, !entry.value.isEmpty {
            tone = invalid ? .bad : .good
            word = invalid ? "invalid" : secret ? "set (hidden)" : String(entry.value.prefix(34)) + (entry.value.count > 34 ? "…" : "")
        } else {
            tone = need == .required ? .bad : need == .warns ? .warn : .neutral
            word = need == .optional ? "not set" : "missing"
        }
        return HStack(spacing: 8) {
            Image(systemName: tone.icon).foregroundStyle(tone.color).font(.caption)
            Text(label).font(.callout.weight(.medium))
            Text(word + (entry.map { " · line \($0.line)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Syntax Badge

private struct SyntaxBadge: View {
    let label: String
    let present: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: present ? "checkmark" : "minus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(present ? Color.green : Color.red)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(present ? "present" : "missing")")
    }
}
