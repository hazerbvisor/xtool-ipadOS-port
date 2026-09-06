import SwiftUI
import UIKit
import XToolMobileCore

struct IDEEditorCommand {
    var id = UUID()
    enum Action { case jump(Int, Int), find(String), replace(String, String, Bool) }
    let action: Action
}

struct IDECodeEditor: UIViewRepresentable {
    @Binding var text: String
    let language: IDELanguage
    var command: IDEEditorCommand? = nil
    var symbols: [String] = []
    var diagnostics: [MobileSourceDiagnostic] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> EditorContainerView {
        let view = EditorContainerView()
        view.textView.delegate = context.coordinator
        view.textView.text = text
        view.textView.keyboardDismissMode = .interactive
        view.textView.autocorrectionType = .no
        view.textView.autocapitalizationType = .none
        view.textView.smartQuotesType = .no
        view.textView.smartDashesType = .no
        view.textView.smartInsertDeleteType = .no
        view.textView.isFindInteractionEnabled = true
        view.textView.alwaysBounceVertical = true
        view.textView.alwaysBounceHorizontal = true
        view.textView.showsHorizontalScrollIndicator = true
        view.textView.textContainer.widthTracksTextView = false
        view.textView.textContainer.lineFragmentPadding = 12
        view.textView.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 16)
        view.textView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textView.backgroundColor = .clear
        view.backgroundColor = .secondarySystemBackground
        view.gutter.backgroundColor = .tertiarySystemBackground
        view.gutter.textColor = .secondaryLabel
        view.gutter.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        view.gutter.textAlignment = .right
        view.gutter.numberOfLines = 0
        view.gutter.isUserInteractionEnabled = false
        context.coordinator.container = view
        context.coordinator.applyHighlighting(to: view.textView, preservingSelection: false)
        context.coordinator.updateLineNumbers()
        context.coordinator.updateCompletions()
        return view
    }

    func updateUIView(_ uiView: EditorContainerView, context: Context) {
        context.coordinator.parent = self
        if uiView.textView.text != text {
            uiView.textView.text = text
            context.coordinator.applyHighlighting(to: uiView.textView, preservingSelection: false)
        }
        context.coordinator.updateLineNumbers()
        if context.coordinator.lastDiagnostics != diagnostics {
            context.coordinator.lastDiagnostics = diagnostics
            context.coordinator.applyHighlighting(to: uiView.textView, preservingSelection: true)
        }
        if let command, context.coordinator.lastCommand != command.id {
            context.coordinator.lastCommand = command.id
            DispatchQueue.main.async { context.coordinator.execute(command.action) }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IDECodeEditor
        weak var container: EditorContainerView?
        private var isApplyingHighlighting = false
        var lastCommand: UUID?
        var lastDiagnostics: [MobileSourceDiagnostic] = []
        private let suggestions = UIToolbar()
        private var completionRange = NSRange(location: 0, length: 0)

        init(parent: IDECodeEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlighting else { return }
            parent.text = textView.text
            applyHighlighting(to: textView, preservingSelection: true)
            updateLineNumbers()
            updateCompletions()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            container?.setNeedsLayout()
            if !isApplyingHighlighting { updateCompletions() }
        }

        func execute(_ action: IDEEditorCommand.Action) {
            guard let view = container?.textView else { return }
            let text = (view.text ?? "") as NSString
            switch action {
            case .jump(let line, let column):
                let rows = (view.text ?? "").components(separatedBy: "\n")
                let row = max(0, min(line - 1, rows.count - 1))
                let offset = rows.prefix(row).reduce(0) { $0 + ($1 as NSString).length + 1 }
                view.selectedRange = NSRange(location: min(text.length, offset + max(0, min(column - 1, (rows[row] as NSString).length))), length: 0)
            case .find(let query):
                guard !query.isEmpty else { return }
                let start = min(text.length, NSMaxRange(view.selectedRange))
                var range = text.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: text.length - start))
                if range.location == NSNotFound { range = text.range(of: query, options: .caseInsensitive) }
                guard range.location != NSNotFound else { return }
                view.selectedRange = range
            case .replace(let query, let replacement, let all):
                guard !query.isEmpty else { return }
                if all {
                    let updated = text.replacingOccurrences(of: query, with: replacement, options: .caseInsensitive, range: NSRange(location: 0, length: text.length))
                    view.selectedRange = NSRange(location: 0, length: text.length)
                    view.insertText(updated)
                } else {
                    let selected = view.selectedRange
                    if selected.length > 0, text.substring(with: selected).caseInsensitiveCompare(query) == .orderedSame { view.insertText(replacement) }
                    execute(.find(query))
                }
            }
            view.becomeFirstResponder()
            view.scrollRangeToVisible(view.selectedRange)
        }

        func updateCompletions() {
            guard let view = container?.textView else { return }
            let text = (view.text ?? "") as NSString
            let caret = min(view.selectedRange.location, text.length)
            let prefixText = text.substring(with: NSRange(location: max(0, caret - 100), length: min(100, caret)))
            let regex = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*$"#)
            let range = regex?.firstMatch(in: prefixText, range: NSRange(location: 0, length: (prefixText as NSString).length))?.range
            let prefix = range.map { (prefixText as NSString).substring(with: $0) } ?? ""
            completionRange = NSRange(location: caret - (prefix as NSString).length, length: (prefix as NSString).length)
            let keywords = ["func", "struct", "class", "protocol", "extension", "import", "return", "guard", "private", "public", "static", "async", "await", "throws", "String", "Int", "Bool", "View", "Text", "VStack", "HStack", "Button", "ForEach"]
            let names = Set(parent.symbols + keywords)
            let candidates = prefix.count >= 2 ? Array(names.filter { $0 != prefix && $0.lowercased().hasPrefix(prefix.lowercased()) }.sorted().prefix(4)) : []
            var items = [UIBarButtonItem(title: "⇥", style: .plain, target: self, action: #selector(indent))]
            items += candidates.map { UIBarButtonItem(title: $0, style: .plain, target: self, action: #selector(complete(_:))) }
            suggestions.items = items
            suggestions.sizeToFit()
            if view.inputAccessoryView !== suggestions { view.inputAccessoryView = suggestions; view.reloadInputViews() }
        }
        @objc private func indent() { container?.textView.insertText("    ") }
        @objc private func complete(_ sender: UIBarButtonItem) {
            guard let view = container?.textView, let title = sender.title, NSMaxRange(completionRange) <= (view.text as NSString).length else { return }
            view.selectedRange = completionRange
            view.insertText(title)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let container else { return }
            container.gutter.transform = CGAffineTransform(
                translationX: 0,
                y: -scrollView.contentOffset.y
            )
        }

        func applyHighlighting(to textView: UITextView, preservingSelection: Bool) {
            guard !isApplyingHighlighting else { return }
            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }

            let selection = textView.selectedRange
            let attributed = NSMutableAttributedString(attributedString: IDESyntaxHighlighter.highlight(
                textView.text ?? "",
                language: parent.language,
                baseFont: textView.font ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            ))
            let rows = (textView.text ?? "").components(separatedBy: "\n")
            for diagnostic in parent.diagnostics where diagnostic.line > 0 && diagnostic.line <= rows.count {
                let row = diagnostic.line - 1
                let offset = rows.prefix(row).reduce(0) { $0 + ($1 as NSString).length + 1 }
                let length = (rows[row] as NSString).length
                if length > 0 {
                    attributed.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: diagnostic.severity == "error" ? UIColor.systemRed : UIColor.systemOrange], range: NSRange(location: offset, length: length))
                }
            }
            textView.attributedText = attributed
            if preservingSelection {
                let maxLocation = attributed.length
                let safeLocation = min(selection.location, maxLocation)
                let safeLength = min(selection.length, maxLocation - safeLocation)
                textView.selectedRange = NSRange(location: safeLocation, length: safeLength)
            }
        }

        func updateLineNumbers() {
            guard let container else { return }
            let count = max(1, (container.textView.text ?? "").reduce(into: 1) { partial, character in
                if character == "\n" { partial += 1 }
            })
            container.gutter.text = (1...count).map(String.init).joined(separator: "\n")
            container.setNeedsLayout()
        }
    }
}

final class EditorContainerView: UIView {
    let gutter = UILabel()
    let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(gutter)
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineCount = max(1, (textView.text ?? "").reduce(into: 1) { partial, character in
            if character == "\n" { partial += 1 }
        })
        let digits = max(2, String(lineCount).count)
        let gutterWidth = CGFloat(24 + digits * 9)
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth - 6, height: max(bounds.height + textView.contentOffset.y, textView.contentSize.height + 30))
        textView.frame = CGRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
    }
}

enum IDELanguage: String, Sendable {
    case swift
    case c
    case cpp
    case objectiveC
    case objectiveCpp
    case plainText

    static func infer(from fileName: String) -> IDELanguage {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "swift": return .swift
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hpp", "hh": return .cpp
        case "m": return .objectiveC
        case "mm": return .objectiveCpp
        default: return .plainText
        }
    }
}

private enum IDESyntaxHighlighter {
    static func highlight(_ source: String, language: IDELanguage, baseFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: baseFont,
                .foregroundColor: UIColor.label
            ]
        )
        guard language != .plainText, !source.isEmpty else { return result }

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        apply(pattern: "//.*$|/\\*[\\s\\S]*?\\*/", options: [.anchorsMatchLines], color: .systemGreen, to: result, range: fullRange)
        apply(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", color: .systemRed, to: result, range: fullRange)
        apply(pattern: "\\b(?:0x[0-9A-Fa-f]+|\\d+(?:\\.\\d+)?)\\b", color: .systemOrange, to: result, range: fullRange)

        let keywords: [String]
        switch language {
        case .swift:
            keywords = [
                "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"
            ]
        case .c, .cpp, .objectiveC, .objectiveCpp:
            keywords = [
                "auto", "bool", "break", "case", "char", "class", "const", "continue", "default", "delete", "do", "double", "else", "enum", "extern", "false", "float", "for", "if", "inline", "int", "long", "namespace", "new", "nullptr", "private", "protected", "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"
            ]
        case .plainText:
            keywords = []
        }

        if !keywords.isEmpty {
            let escaped = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            apply(pattern: "\\b(?:\(escaped))\\b", color: .systemPurple, to: result, range: fullRange)
        }

        if language == .swift {
            apply(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b", color: .systemTeal, to: result, range: fullRange)
            apply(pattern: "@[A-Za-z_][A-Za-z0-9_]*", color: .systemIndigo, to: result, range: fullRange)
        } else {
            apply(pattern: "^\\s*#\\s*[A-Za-z_]+", options: [.anchorsMatchLines], color: .systemPink, to: result, range: fullRange)
        }

        // Apply comments and strings last as complete tokens so keyword/type
        // coloring cannot overwrite text inside them.
        if let tokens = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/"#) {
            for match in tokens.matches(in: source, range: fullRange) {
                let value = (source as NSString).substring(with: match.range)
                result.addAttribute(.foregroundColor, value: value.hasPrefix("\"") ? UIColor.systemRed : UIColor.systemGreen, range: match.range)
            }
        }
        return result
    }

    private static func apply(
        pattern: String,
        options: NSRegularExpression.Options = [],
        color: UIColor,
        to string: NSMutableAttributedString,
        range: NSRange
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        for match in regex.matches(in: string.string, range: range) {
            string.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
