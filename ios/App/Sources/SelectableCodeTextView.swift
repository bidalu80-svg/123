import SwiftUI
import UIKit

struct SelectableCodeTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var font: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var lineSpacing: CGFloat = 3
    var language: String? = nil
    var codeThemeMode: CodeThemeMode = .followApp
    var isDarkMode: Bool = false
    var isScrollEnabled: Bool = false
    var maximumHeight: CGFloat? = nil
    var autoFollowTail: Bool = false
    var disableSyntaxHighlighting: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = NoCaretTextView()
        view.isEditable = false
        view.isSelectable = true
        view.tintColor = .clear
        view.isScrollEnabled = isScrollEnabled
        view.showsVerticalScrollIndicator = isScrollEnabled
        view.alwaysBounceVertical = isScrollEnabled
        view.scrollsToTop = false
        view.backgroundColor = .clear
        view.dataDetectorTypes = []
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.textContainer.lineBreakMode = .byWordWrapping
        view.layoutManager.allowsNonContiguousLayout = false
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.panGestureRecognizer.isEnabled = true
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        uiView.selectedTextRange = nil
        if uiView.isScrollEnabled != isScrollEnabled {
            uiView.isScrollEnabled = isScrollEnabled
        }
        uiView.showsVerticalScrollIndicator = isScrollEnabled
        uiView.alwaysBounceVertical = isScrollEnabled

        let normalizedMaximumHeight = maximumHeight ?? -1
        let shouldRebuild =
            coordinator.lastText != text
            || coordinator.lastLineSpacing != lineSpacing
            || coordinator.lastFontPointSize != font.pointSize
            || !coordinator.lastTextColor.isEqual(textColor)
            || coordinator.lastLanguage != language
            || coordinator.lastCodeThemeModeRaw != codeThemeMode.rawValue
            || coordinator.lastIsDarkMode != isDarkMode
            || coordinator.lastIsScrollEnabled != isScrollEnabled
            || abs(coordinator.lastMaximumHeight - normalizedMaximumHeight) > 0.5
            || coordinator.lastAutoFollowTail != autoFollowTail
            || coordinator.lastDisableSyntaxHighlighting != disableSyntaxHighlighting

        guard shouldRebuild else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        if coordinator.lastText.isEmpty || !text.hasPrefix(coordinator.lastText) {
            uiView.attributedText = renderCode(
                code: text,
                attributes: attributes,
                language: language,
                codeThemeMode: codeThemeMode,
                isDarkMode: isDarkMode,
                disableSyntaxHighlighting: disableSyntaxHighlighting
            )
        } else {
            let suffix = String(text.dropFirst(coordinator.lastText.count))
            if !suffix.isEmpty {
                uiView.textStorage.append(
                    renderCode(
                        code: suffix,
                        attributes: attributes,
                        language: language,
                        codeThemeMode: codeThemeMode,
                        isDarkMode: isDarkMode,
                        disableSyntaxHighlighting: disableSyntaxHighlighting
                    )
                )
            }
        }

        coordinator.lastText = text
        coordinator.lastLineSpacing = lineSpacing
        coordinator.lastFontPointSize = font.pointSize
        coordinator.lastTextColor = textColor
        coordinator.lastLanguage = language
        coordinator.lastCodeThemeModeRaw = codeThemeMode.rawValue
        coordinator.lastIsDarkMode = isDarkMode
        coordinator.lastIsScrollEnabled = isScrollEnabled
        coordinator.lastMaximumHeight = normalizedMaximumHeight
        coordinator.lastAutoFollowTail = autoFollowTail
        coordinator.lastDisableSyntaxHighlighting = disableSyntaxHighlighting

        if isScrollEnabled, autoFollowTail {
            scrollToLatestCode(in: uiView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1 else { return nil }
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        let fitted = uiView.sizeThatFits(target)
        let height = ceil(fitted.height)
        if let maximumHeight, maximumHeight > 0 {
            if isScrollEnabled && autoFollowTail {
                return CGSize(width: width, height: maximumHeight)
            }
            return CGSize(width: width, height: min(height, maximumHeight))
        }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject {
        var lastText = ""
        var lastLineSpacing: CGFloat = 0
        var lastFontPointSize: CGFloat = 0
        var lastTextColor: UIColor = .clear
        var lastLanguage: String?
        var lastCodeThemeModeRaw: String = ""
        var lastIsDarkMode = false
        var lastIsScrollEnabled = false
        var lastMaximumHeight: CGFloat = -1
        var lastAutoFollowTail = false
        var lastDisableSyntaxHighlighting = false
    }

    private func scrollToLatestCode(in uiView: UITextView) {
        DispatchQueue.main.async {
            guard uiView.isScrollEnabled else { return }

            UIView.performWithoutAnimation {
                uiView.layoutIfNeeded()
                let bottomOffsetY = max(
                    -uiView.adjustedContentInset.top,
                    uiView.contentSize.height - uiView.bounds.height + uiView.adjustedContentInset.bottom
                )
                uiView.setContentOffset(
                    CGPoint(x: uiView.contentOffset.x, y: bottomOffsetY),
                    animated: false
                )
            }
        }
    }

    private func renderCode(
        code: String,
        attributes: [NSAttributedString.Key: Any],
        language: String?,
        codeThemeMode: CodeThemeMode,
        isDarkMode: Bool,
        disableSyntaxHighlighting: Bool
    ) -> NSAttributedString {
        if disableSyntaxHighlighting {
            return NSAttributedString(string: code, attributes: attributes)
        }
        return highlightedCode(
            code: code,
            attributes: attributes,
            language: language,
            codeThemeMode: codeThemeMode,
            isDarkMode: isDarkMode
        )
    }

    private struct SyntaxPalette {
        let keyword: UIColor
        let string: UIColor
        let number: UIColor
        let comment: UIColor
        let function: UIColor
        let type: UIColor
    }

    private func highlightedCode(
        code: String,
        attributes: [NSAttributedString.Key: Any],
        language: String?,
        codeThemeMode: CodeThemeMode,
        isDarkMode: Bool
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(string: code, attributes: attributes)
        guard !code.isEmpty else { return output }

        let palette = syntaxPalette(codeThemeMode: codeThemeMode, isDarkMode: isDarkMode)
        let keywords = keywordSet(language: language)

        applyColor(palette.comment, pattern: "(?m)#.*$|//.*$", in: output)
        applyColor(palette.comment, pattern: "(?s)/\\*.*?\\*/", in: output)
        applyColor(palette.string, pattern: "\"(\\\\.|[^\"])*\"|'(\\\\.|[^'])*'", in: output)
        applyColor(palette.number, pattern: "\\b\\d+(\\.\\d+)?\\b", in: output)
        applyColor(palette.keyword, pattern: "\\b(\(keywords.joined(separator: "|")))\\b", in: output)
        applyColor(palette.type, pattern: "\\b([A-Z][A-Za-z0-9_]*)\\b", in: output)
        applyColor(palette.function, pattern: "\\b([a-zA-Z_][A-Za-z0-9_]*)\\s*(?=\\()", in: output)
        return output
    }

    private func syntaxPalette(codeThemeMode: CodeThemeMode, isDarkMode: Bool) -> SyntaxPalette {
        let useDarkPalette: Bool = {
            switch codeThemeMode {
            case .vscodeDark:
                return true
            case .githubLight:
                return false
            case .followApp:
                return isDarkMode
            }
        }()

        if useDarkPalette {
            return SyntaxPalette(
                keyword: UIColor(red: 0.63, green: 0.96, blue: 0.70, alpha: 1),
                string: UIColor(red: 0.93, green: 0.80, blue: 0.48, alpha: 1),
                number: UIColor(red: 0.76, green: 0.95, blue: 0.60, alpha: 1),
                comment: MinisTheme.codeComment,
                function: UIColor(red: 0.79, green: 0.95, blue: 0.67, alpha: 1),
                type: UIColor(red: 0.55, green: 0.93, blue: 0.82, alpha: 1)
            )
        }

        return SyntaxPalette(
            keyword: UIColor(red: 0.69, green: 0.00, blue: 0.86, alpha: 1),
            string: UIColor(red: 0.64, green: 0.08, blue: 0.08, alpha: 1),
            number: UIColor(red: 0.04, green: 0.53, blue: 0.34, alpha: 1),
            comment: UIColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1),
            function: UIColor(red: 0.47, green: 0.37, blue: 0.15, alpha: 1),
            type: UIColor(red: 0.15, green: 0.50, blue: 0.60, alpha: 1)
        )
    }

    private func keywordSet(language: String?) -> [String] {
        switch (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "swift":
            return ["let", "var", "func", "struct", "class", "enum", "if", "else", "guard", "return", "import", "protocol", "extension"]
        case "python", "py":
            return ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "try", "except", "with", "as"]
        case "javascript", "js", "typescript", "ts":
            return ["const", "let", "var", "function", "class", "if", "else", "return", "import", "export", "async", "await"]
        case "json":
            return ["true", "false", "null"]
        default:
            return ["if", "else", "for", "while", "return", "class", "func", "def", "const", "let", "var", "import"]
        }
    }

    private func applyColor(_ color: UIColor, pattern: String, in text: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let plain = text.string
        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in regex.matches(in: plain, range: nsRange) {
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
