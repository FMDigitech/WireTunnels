import SwiftUI
import AppKit

// MARK: - Syntax Highlighting NSTextView

struct SyntaxHighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var readOnly: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

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
        if !readOnly {
            textView.delegate = context.coordinator
        }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        textView.textStorage?.setAttributedString(Self.highlighted(text))

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard !context.coordinator.isUpdating, textView.string != text else { return }
        let sel = textView.selectedRange()
        textView.textStorage?.setAttributedString(Self.highlighted(text))
        let maxLoc = text.utf16.count
        textView.setSelectedRange(NSRange(location: min(sel.location, maxLoc), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Highlighting

    static func highlighted(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            result.append(highlightLine(line))
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                ]))
            }
        }
        return result
    }

    private static var baseAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
         .foregroundColor: NSColor.labelColor]
    }

    private static func highlightLine(_ line: String) -> NSAttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            return NSAttributedString(string: line, attributes: baseAttrs)
        }

        // Comment
        if trimmed.hasPrefix("#") {
            return NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.systemGreen
            ])
        }

        // Section header [Interface] / [Peer]
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let color: NSColor = trimmed.lowercased().contains("interface") ? .systemOrange : .systemTeal
            return NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold),
                .foregroundColor: color
            ])
        }

        // Key = Value
        if let eqIdx = line.firstIndex(of: "=") {
            let keyStr = String(line[line.startIndex..<eqIdx])
            let valStr = String(line[line.index(after: eqIdx)...])

            let r = NSMutableAttributedString()
            r.append(NSAttributedString(string: keyStr, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.systemBlue
            ]))
            r.append(NSAttributedString(string: "=", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            r.append(NSAttributedString(string: valStr, attributes: baseAttrs))
            return r
        }

        return NSAttributedString(string: line, attributes: baseAttrs)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightingTextEditor
        var isUpdating = false

        init(_ parent: SyntaxHighlightingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, !isUpdating else { return }
            isUpdating = true
            defer { isUpdating = false }

            let newText = tv.string
            parent.text = newText

            let sel = tv.selectedRange()
            tv.textStorage?.setAttributedString(SyntaxHighlightingTextEditor.highlighted(newText))
            let maxLoc = newText.utf16.count
            let safeLoc = min(sel.location, maxLoc)
            let safeLen = min(sel.length, max(0, maxLoc - safeLoc))
            tv.setSelectedRange(NSRange(location: safeLoc, length: safeLen))
        }
    }
}

// MARK: - Config Editor View

struct ConfigEditorView: View {
    @Binding var content: String
    var readOnly: Bool = false

    @State private var showTemplatePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)

                Text("WireGuard Config")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

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
                SyntaxHighlightingTextEditor(text: $content, readOnly: readOnly)

                if !readOnly && content.isEmpty {
                    Text("[Interface]\nPrivateKey = \nAddress = \n\n[Peer]\nPublicKey = \nEndpoint = \nAllowedIPs = ")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }

            // Status bar
            Divider()

            HStack {
                let lineCount = content.components(separatedBy: .newlines).count
                let charCount = content.count

                Text("\(lineCount) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text("\(charCount) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Syntax hints
                if !readOnly && !content.isEmpty {
                    let hasInterface = content.contains("[Interface]")
                    let hasPeer = content.contains("[Peer]")

                    HStack(spacing: 6) {
                        SyntaxBadge(label: "[Interface]", present: hasInterface)
                        SyntaxBadge(label: "[Peer]", present: hasPeer)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Syntax Badge

private struct SyntaxBadge: View {
    let label: String
    let present: Bool

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(present ? Color.green : Color.red)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
