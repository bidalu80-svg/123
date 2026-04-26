import SwiftUI
import UIKit

final class NoCaretTextView: UITextView {
    override var canBecomeFirstResponder: Bool {
        false
    }

    override var selectedTextRange: UITextRange? {
        get { nil }
        set {}
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        .zero
    }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        []
    }
}

struct StreamingMarkdownTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var linkColor: UIColor = .secondaryLabel
    var font: UIFont = MinisTheme.assistantUIFont

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let renderQueue = DispatchQueue(
        label: "chatapp.streaming.markdown.render",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func renderedAttributedText(
        text: String,
        textColor: UIColor,
        linkColor: UIColor,
        font: UIFont
    ) -> NSAttributedString {
        liveMarkdownAttributedText(
            text: text,
            textColor: textColor,
            linkColor: linkColor,
            font: font
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = NoCaretTextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
        view.tintColor = .clear
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.layoutManager.allowsNonContiguousLayout = false
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.dataDetectorTypes = []
        view.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: 0
        ]
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.shouldRender(
            text: text,
            font: font,
            textColor: textColor,
            linkColor: linkColor
        ) else {
            return
        }

        let textSnapshot = text
        let textColorSnapshot = textColor
        let linkColorSnapshot = linkColor
        let fontSnapshot = font
        let renderToken = coordinator.beginRender()

        if textSnapshot.isEmpty {
            UIView.performWithoutAnimation {
                uiView.attributedText = NSAttributedString()
                uiView.linkTextAttributes = [
                    .foregroundColor: linkColorSnapshot,
                    .underlineStyle: 0
                ]
                uiView.invalidateIntrinsicContentSize()
                uiView.setNeedsLayout()
            }
            coordinator.record(
                text: textSnapshot,
                font: fontSnapshot,
                textColor: textColorSnapshot,
                linkColor: linkColorSnapshot
            )
            return
        }

        Self.renderQueue.async {
            let rendered = Self.renderedAttributedText(
                text: textSnapshot,
                textColor: textColorSnapshot,
                linkColor: linkColorSnapshot,
                font: fontSnapshot
            )
            DispatchQueue.main.async {
                guard coordinator.isCurrentRenderToken(renderToken) else { return }
                UIView.performWithoutAnimation {
                    uiView.attributedText = rendered
                    uiView.linkTextAttributes = [
                        .foregroundColor: linkColorSnapshot,
                        .underlineStyle: 0
                    ]
                    uiView.invalidateIntrinsicContentSize()
                    uiView.setNeedsLayout()
                }
                coordinator.record(
                    text: textSnapshot,
                    font: fontSnapshot,
                    textColor: textColorSnapshot,
                    linkColor: linkColorSnapshot
                )
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1 else { return nil }
        let lineBreakCount = text.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
        if let cached = context.coordinator.cachedSizeIfAvailable(
            forWidth: width,
            textCount: text.count,
            lineBreakCount: lineBreakCount
        ) {
            return cached
        }
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(target)
        let fitted = CGSize(width: width, height: ceil(size.height))
        context.coordinator.recordMeasuredSize(
            fitted,
            width: width,
            textCount: text.count,
            lineBreakCount: lineBreakCount
        )
        return fitted
    }

    final class Coordinator {
        private var lastText = ""
        private var lastFontPointSize: CGFloat = 0
        private var lastTextColor: UIColor = .clear
        private var lastLinkColor: UIColor = .clear
        private var renderToken: Int = 0
        private var lastMeasuredWidth: CGFloat = 0
        private var lastMeasuredHeight: CGFloat = 0
        private var lastMeasuredTextCount: Int = 0
        private var lastMeasuredLineBreakCount: Int = 0

        func shouldRender(text: String, font: UIFont, textColor: UIColor, linkColor: UIColor) -> Bool {
            lastText != text
                || lastFontPointSize != font.pointSize
                || !lastTextColor.isEqual(textColor)
                || !lastLinkColor.isEqual(linkColor)
        }

        func beginRender() -> Int {
            renderToken &+= 1
            return renderToken
        }

        func isCurrentRenderToken(_ token: Int) -> Bool {
            token == renderToken
        }

        func record(text: String, font: UIFont, textColor: UIColor, linkColor: UIColor) {
            lastText = text
            lastFontPointSize = font.pointSize
            lastTextColor = textColor
            lastLinkColor = linkColor
        }

        func cachedSizeIfAvailable(forWidth width: CGFloat, textCount: Int, lineBreakCount: Int) -> CGSize? {
            guard lastMeasuredHeight > 0 else { return nil }
            guard abs(width - lastMeasuredWidth) < 0.5 else { return nil }
            guard textCount >= lastMeasuredTextCount else { return nil }
            guard lineBreakCount >= lastMeasuredLineBreakCount else { return nil }

            let delta = textCount - lastMeasuredTextCount
            let lineDelta = lineBreakCount - lastMeasuredLineBreakCount
            if delta < 160 && lineDelta == 0 {
                return CGSize(width: width, height: lastMeasuredHeight)
            }
            return nil
        }

        func recordMeasuredSize(_ size: CGSize, width: CGFloat, textCount: Int, lineBreakCount: Int) {
            lastMeasuredWidth = width
            lastMeasuredHeight = size.height
            lastMeasuredTextCount = textCount
            lastMeasuredLineBreakCount = lineBreakCount
        }
    }

    private static func liveMarkdownAttributedText(
        text: String,
        textColor: UIColor,
        linkColor: UIColor,
        font: UIFont
    ) -> NSAttributedString {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4.6
        paragraph.paragraphSpacing = 6

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let output = NSMutableAttributedString()
        var inCodeFence = false
        let lines = normalized.components(separatedBy: "\n")

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeFence.toggle()
                if index < lines.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: baseAttributes))
                }
                continue
            }

            let lineAttributes: [NSAttributedString.Key: Any]

            if inCodeFence {
                var codeParagraph = paragraph
                codeParagraph.lineSpacing = 3.2
                lineAttributes = [
                    .font: UIFont.monospacedSystemFont(ofSize: max(13.2, font.pointSize - 1.2), weight: .regular),
                    .foregroundColor: textColor,
                    .paragraphStyle: codeParagraph,
                    .backgroundColor: UIColor.secondarySystemBackground.withAlphaComponent(0.55)
                ]
                output.append(NSAttributedString(string: rawLine, attributes: lineAttributes))
            } else {
                let parsed = parseLinePrefix(rawLine, baseFont: font)
                lineAttributes = [
                    .font: parsed.font,
                    .foregroundColor: parsed.color ?? textColor,
                    .paragraphStyle: parsed.paragraph ?? paragraph
                ]
                appendInlineMarkdown(
                    parsed.text,
                    to: output,
                    baseAttributes: lineAttributes,
                    baseFont: parsed.font,
                    linkColor: linkColor
                )
            }

            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
        }

        addDetectedLinks(to: output, text: output.string, linkColor: linkColor)
        return output
    }

    private static func parseLinePrefix(
        _ rawLine: String,
        baseFont: UIFont
    ) -> (text: String, font: UIFont, color: UIColor?, paragraph: NSMutableParagraphStyle?) {
        let leadingWhitespace = rawLine.prefix { $0 == " " || $0 == "\t" }
        let leading = String(leadingWhitespace)
        let trimmedStart = String(rawLine.dropFirst(leading.count))

        if let markerEnd = trimmedStart.firstIndex(where: { $0 != "#" }) {
            let hashes = trimmedStart[..<markerEnd]
            if (1...6).contains(hashes.count), trimmedStart[markerEnd] == " " {
                let title = String(trimmedStart[trimmedStart.index(after: markerEnd)...])
                let sizeBoost = max(0, 7 - hashes.count)
                let headingFont = UIFont.systemFont(ofSize: baseFont.pointSize + CGFloat(sizeBoost), weight: .semibold)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 3.8
                paragraph.paragraphSpacing = hashes.count <= 2 ? 10 : 7
                return (leading + title, headingFont, nil, paragraph)
            }
        }

        if trimmedStart.hasPrefix(">") {
            let stripped = trimmedStart.dropFirst().trimmingCharacters(in: .whitespaces)
            return (leading + String(stripped), baseFont, UIColor.secondaryLabel, nil)
        }

        for marker in ["- ", "* ", "+ "] where trimmedStart.hasPrefix(marker) {
            return (leading + "• " + String(trimmedStart.dropFirst(marker.count)), baseFont, nil, nil)
        }

        return (rawLine, baseFont, nil, nil)
    }

    private static func appendInlineMarkdown(
        _ text: String,
        to output: NSMutableAttributedString,
        baseAttributes: [NSAttributedString.Key: Any],
        baseFont: UIFont,
        linkColor: UIColor
    ) {
        var cursor = text.startIndex

        func append(_ value: String, attributes: [NSAttributedString.Key: Any]) {
            guard !value.isEmpty else { return }
            output.append(NSAttributedString(string: value, attributes: attributes))
        }

        while cursor < text.endIndex {
            if text[cursor] == "`",
               let close = text[text.index(after: cursor)...].firstIndex(of: "`") {
                let code = String(text[text.index(after: cursor)..<close])
                var attributes = baseAttributes
                attributes[.font] = UIFont.monospacedSystemFont(ofSize: max(13.0, baseFont.pointSize - 0.8), weight: .regular)
                attributes[.backgroundColor] = UIColor.secondarySystemBackground.withAlphaComponent(0.72)
                append(code, attributes: attributes)
                cursor = text.index(after: close)
                continue
            }

            if let parsed = parseDelimitedInline(
                in: text,
                from: cursor,
                marker: "**",
                baseAttributes: baseAttributes,
                baseFont: baseFont
            ) {
                append(parsed.value, attributes: parsed.attributes)
                cursor = parsed.next
                continue
            }

            if let parsed = parseDelimitedInline(
                in: text,
                from: cursor,
                marker: "__",
                baseAttributes: baseAttributes,
                baseFont: baseFont
            ) {
                append(parsed.value, attributes: parsed.attributes)
                cursor = parsed.next
                continue
            }

            if text[cursor] == "[",
               let labelEnd = text[cursor...].firstIndex(of: "]"),
               labelEnd < text.index(before: text.endIndex),
               text[text.index(after: labelEnd)] == "(",
               let urlEnd = text[text.index(labelEnd, offsetBy: 2)...].firstIndex(of: ")") {
                let label = String(text[text.index(after: cursor)..<labelEnd])
                let rawURL = String(text[text.index(labelEnd, offsetBy: 2)..<urlEnd])
                var attributes = baseAttributes
                if let url = URL(string: rawURL) {
                    attributes[.link] = url
                    attributes[.foregroundColor] = linkColor
                    attributes[.underlineStyle] = 0
                }
                append(label, attributes: attributes)
                cursor = text.index(after: urlEnd)
                continue
            }

            let nextMarker = nextInlineMarker(in: text, from: text.index(after: cursor)) ?? text.endIndex
            append(String(text[cursor..<nextMarker]), attributes: baseAttributes)
            cursor = nextMarker
        }
    }

    private static func parseDelimitedInline(
        in text: String,
        from cursor: String.Index,
        marker: String,
        baseAttributes: [NSAttributedString.Key: Any],
        baseFont: UIFont
    ) -> (value: String, attributes: [NSAttributedString.Key: Any], next: String.Index)? {
        guard text[cursor...].hasPrefix(marker) else { return nil }
        let contentStart = text.index(cursor, offsetBy: marker.count)
        guard let close = text[contentStart...].range(of: marker)?.lowerBound else { return nil }
        let value = String(text[contentStart..<close])
        var attributes = baseAttributes
        attributes[.font] = UIFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
        return (value, attributes, text.index(close, offsetBy: marker.count))
    }

    private static func nextInlineMarker(in text: String, from cursor: String.Index) -> String.Index? {
        var nearest: String.Index?
        for marker in ["`", "**", "__", "["] {
            if let range = text[cursor...].range(of: marker) {
                if nearest == nil || range.lowerBound < nearest! {
                    nearest = range.lowerBound
                }
            }
        }
        return nearest
    }

    private static func addDetectedLinks(
        to output: NSMutableAttributedString,
        text: String,
        linkColor: UIColor
    ) {
        guard text.count <= 9_000, let detector = linkDetector else { return }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            output.addAttributes(
                [
                    .link: url,
                    .foregroundColor: linkColor,
                    .underlineStyle: 0
                ],
                range: match.range
            )
        }
    }
}

struct SelectableLinkTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var linkColor: UIColor = .secondaryLabel
    var font: UIFont = MinisTheme.assistantUIFont
    var renderMarkdown: Bool = false
    var streamingAnimated: Bool = false
    var onFileLinkTap: ((String) -> Void)? = nil
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let markdownRenderQueue = DispatchQueue(label: "chatapp.markdown.render", qos: .userInitiated)
    private static let fileLinkScheme = "iexa-file"
    private static let maxURLLinkDetectionCharacters = 9_000
    private static let maxProjectPathLinkDetectionCharacters = 5_500
    private static let projectPathRegex = try? NSRegularExpression(
        pattern: #"(?:^|[\s\(\[<"'`])((?:[A-Za-z0-9._\-]+/)*[A-Za-z0-9._\-]+\.[A-Za-z0-9_+\-]{1,12})(?=$|[\s\)\]>,:;"'`])"#
    )
    private static let pathLikeExtensions: Set<String> = [
        "txt", "md", "json", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "xml", "html", "css", "scss", "less", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "py", "swift", "go", "rs", "java", "kt", "kts", "c", "h", "hpp", "hh", "cc", "cpp", "cxx",
        "cs", "php", "rb", "lua", "sql", "sh", "bash", "zsh", "ps1", "dockerfile", "makefile", "gradle", "properties", "lock"
    ]
    private static let pathLikeFileNames: Set<String> = [
        "dockerfile", "makefile", "cmakelists.txt", "readme", "readme.md", "package.json",
        "requirements.txt", "pyproject.toml", "cargo.toml", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts"
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(onFileLinkTap: onFileLinkTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = NoCaretTextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
        view.tintColor = .clear
        view.scrollsToTop = false
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        // Non-contiguous layout can cause transient blank gaps while fast-scrolling very long text.
        view.layoutManager.allowsNonContiguousLayout = false
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.dataDetectorTypes = []
        view.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: 0
        ]
        // Keep selection gestures enabled so users can long-press and select partial text.
        view.panGestureRecognizer.isEnabled = true
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onFileLinkTap = onFileLinkTap
        let shouldRebuildText =
            coordinator.lastText != text
            || coordinator.lastFontPointSize != font.pointSize
            || !coordinator.lastTextColor.isEqual(textColor)
            || !coordinator.lastLinkColor.isEqual(linkColor)
            || coordinator.lastRenderMarkdown != renderMarkdown
            || coordinator.lastStreamingAnimated != streamingAnimated
        if !shouldRebuildText {
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4.6

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        if renderMarkdown {
            coordinator.stopStreamingAnimation(clearPending: true)
            coordinator.markdownRenderToken &+= 1
            let renderToken = coordinator.markdownRenderToken
            let markdownSource = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if markdownSource.isEmpty {
                uiView.attributedText = NSAttributedString()
                coordinator.lastMarkdownSource = ""
                coordinator.cachedMarkdown = NSAttributedString()
                coordinator.lastMarkdownFontPointSize = font.pointSize
                coordinator.lastMarkdownTextColor = textColor
                coordinator.lastMarkdownLinkColor = linkColor
            } else if coordinator.lastMarkdownSource == markdownSource,
                      coordinator.lastMarkdownFontPointSize == font.pointSize,
                      coordinator.lastMarkdownTextColor.isEqual(textColor),
                      coordinator.lastMarkdownLinkColor.isEqual(linkColor),
                      let cached = coordinator.cachedMarkdown {
                uiView.attributedText = cached
            } else {
                uiView.attributedText = NSAttributedString(string: markdownSource, attributes: attrs)

                let applyRendered: (NSAttributedString) -> Void = { rendered in
                    guard coordinator.markdownRenderToken == renderToken else { return }
                    uiView.attributedText = rendered
                    coordinator.lastMarkdownSource = markdownSource
                    coordinator.cachedMarkdown = rendered
                    coordinator.lastMarkdownFontPointSize = font.pointSize
                    coordinator.lastMarkdownTextColor = textColor
                    coordinator.lastMarkdownLinkColor = linkColor
                }

                if markdownSource.count <= 1_400 {
                    let rendered = Self.markdownAttributedText(
                        text: markdownSource,
                        textColor: textColor,
                        linkColor: linkColor,
                        font: font
                    )
                    applyRendered(rendered)
                } else {
                    let textColorSnapshot = textColor
                    let linkColorSnapshot = linkColor
                    let fontSnapshot = font
                    Self.markdownRenderQueue.async {
                        let rendered = Self.markdownAttributedText(
                            text: markdownSource,
                            textColor: textColorSnapshot,
                            linkColor: linkColorSnapshot,
                            font: fontSnapshot
                        )
                        DispatchQueue.main.async {
                            applyRendered(rendered)
                        }
                    }
                }
            }
        } else {
            coordinator.configureStreamingAnimation(
                textView: uiView,
                attributes: attrs,
                enabled: streamingAnimated
            )
            coordinator.markdownRenderToken &+= 1
            coordinator.lastMarkdownSource = ""
            coordinator.cachedMarkdown = nil
            coordinator.lastMarkdownFontPointSize = 0
            coordinator.lastMarkdownTextColor = .clear
            coordinator.lastMarkdownLinkColor = .clear

            let fullTextChangedShape = coordinator.lastText.isEmpty || !text.hasPrefix(coordinator.lastText)
            let isLeavingStreamingMode = !streamingAnimated && coordinator.lastStreamingAnimated
            if fullTextChangedShape {
                coordinator.stopStreamingAnimation(clearPending: true)
                if streamingAnimated && coordinator.lastText.isEmpty && !text.isEmpty {
                    uiView.attributedText = NSAttributedString()
                    coordinator.queueStreamingSuffix(text)
                } else {
                    let attributed = NSMutableAttributedString(string: text, attributes: attrs)
                    if Self.shouldRunURLLinkDetection(for: text),
                       let detector = Self.linkDetector {
                        let nsText = text as NSString
                        let fullRange = NSRange(location: 0, length: nsText.length)
                        detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                            guard let match, let url = match.url else { return }
                            attributed.addAttributes(
                                [
                                    .link: url,
                                    .foregroundColor: linkColor,
                                    .underlineStyle: 0
                                ],
                                range: match.range
                            )
                        }
                    }
                    if Self.shouldRunProjectPathLinkDetection(for: text) {
                        Self.addProjectPathLinks(
                            to: attributed,
                            sourceText: text,
                            linkColor: linkColor
                        )
                    }
                    uiView.attributedText = attributed
                }
            } else {
                if isLeavingStreamingMode {
                    coordinator.stopStreamingAnimation(clearPending: false, normalizeTail: true)
                }
                let suffix = String(text.dropFirst(coordinator.lastText.count))
                if !suffix.isEmpty {
                    if streamingAnimated {
                        coordinator.queueStreamingSuffix(suffix)
                    } else {
                        let appended = NSMutableAttributedString(string: suffix, attributes: attrs)
                        if Self.shouldRunURLLinkDetection(for: suffix),
                           let detector = Self.linkDetector {
                            let nsText = suffix as NSString
                            let fullRange = NSRange(location: 0, length: nsText.length)
                            detector.enumerateMatches(in: suffix, options: [], range: fullRange) { match, _, _ in
                                guard let match, let url = match.url else { return }
                                appended.addAttributes(
                                    [
                                        .link: url,
                                        .foregroundColor: linkColor,
                                        .underlineStyle: 0
                                    ],
                                    range: match.range
                                )
                            }
                        }
                        if Self.shouldRunProjectPathLinkDetection(for: suffix) {
                            Self.addProjectPathLinks(
                                to: appended,
                                sourceText: suffix,
                                linkColor: linkColor
                            )
                        }
                        uiView.textStorage.append(appended)
                    }
                }
            }
        }

        uiView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: 0
        ]
        uiView.selectedTextRange = nil
        uiView.invalidateIntrinsicContentSize()
        uiView.setNeedsLayout()
        coordinator.lastText = text
        coordinator.lastFontPointSize = font.pointSize
        coordinator.lastTextColor = textColor
        coordinator.lastLinkColor = linkColor
        coordinator.lastRenderMarkdown = renderMarkdown
        coordinator.lastStreamingAnimated = streamingAnimated
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1 else { return nil }
        let lineBreakCount = text.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
        if let cached = context.coordinator.cachedSizeIfAvailable(
            forWidth: width,
            textCount: text.count,
            lineBreakCount: lineBreakCount
        ) {
            return cached
        }
        if text.count >= 8_000 {
            uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        }
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(target)
        let fitted = CGSize(width: width, height: ceil(size.height))
        context.coordinator.recordMeasuredSize(
            fitted,
            width: width,
            textCount: text.count,
            lineBreakCount: lineBreakCount
        )
        return fitted
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.stopStreamingAnimation(clearPending: true)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastText: String = ""
        var lastFontPointSize: CGFloat = 0
        var lastTextColor: UIColor = .clear
        var lastLinkColor: UIColor = .clear
        var lastRenderMarkdown: Bool = false
        var lastStreamingAnimated: Bool = false
        var markdownRenderToken: Int = 0
        var lastMarkdownSource: String = ""
        var cachedMarkdown: NSAttributedString?
        var lastMarkdownFontPointSize: CGFloat = 0
        var lastMarkdownTextColor: UIColor = .clear
        var lastMarkdownLinkColor: UIColor = .clear
        private weak var activeTextView: UITextView?
        private var streamTimer: CADisplayLink?
        private var streamLastTimestamp: CFTimeInterval = 0
        private var pendingStreamingSuffix = ""
        private var streamAttributes: [NSAttributedString.Key: Any] = [:]
        private var streamAnimationEnabled = false
        private var streamPrimaryColor: UIColor = .label
        private var lastStreamingTailRange: NSRange?
        private var lastStreamingCursorRange: NSRange?
        private var streamCharacterBudget: Double = 0
        private var streamPauseRemaining: CFTimeInterval = 0
        private var lastMeasuredWidth: CGFloat = 0
        private var lastMeasuredHeight: CGFloat = 0
        private var lastMeasuredTextCount: Int = 0
        private var lastMeasuredLineBreakCount: Int = 0
        var onFileLinkTap: ((String) -> Void)?

        init(onFileLinkTap: ((String) -> Void)?) {
            self.onFileLinkTap = onFileLinkTap
            super.init()
        }

        deinit {
            stopStreamingAnimation(clearPending: true)
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            if let filePath = SelectableLinkTextView.filePath(fromProjectLink: URL) {
                onFileLinkTap?(filePath)
                return false
            }
            if interaction == .invokeDefaultAction {
                UIApplication.shared.open(URL)
                return false
            }
            return true
        }

        func configureStreamingAnimation(
            textView: UITextView,
            attributes: [NSAttributedString.Key: Any],
            enabled: Bool
        ) {
            activeTextView = textView
            streamAttributes = attributes
            streamPrimaryColor = (attributes[.foregroundColor] as? UIColor) ?? .label
            streamAnimationEnabled = enabled
            if !enabled {
                stopStreamingAnimation(clearPending: true)
            }
        }

        func queueStreamingSuffix(_ suffix: String) {
            guard streamAnimationEnabled, !suffix.isEmpty else { return }
            pendingStreamingSuffix.append(suffix)
            startStreamingAnimationIfNeeded()
        }

        func stopStreamingAnimation(clearPending: Bool, normalizeTail: Bool = true) {
            if normalizeTail {
                normalizeStreamingTailAppearance()
            }
            streamTimer?.invalidate()
            streamTimer = nil
            streamLastTimestamp = 0
            streamCharacterBudget = 0
            streamPauseRemaining = 0
            if clearPending {
                pendingStreamingSuffix.removeAll(keepingCapacity: false)
            }
        }

        private func startStreamingAnimationIfNeeded() {
            guard streamTimer == nil else { return }
            let timer = CADisplayLink(target: self, selector: #selector(handleStreamAnimationTick(_:)))
            if #available(iOS 15.0, *) {
                timer.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            } else {
                timer.preferredFramesPerSecond = 30
            }
            timer.add(to: .main, forMode: .common)
            streamTimer = timer
            streamLastTimestamp = 0
        }

        @objc
        private func handleStreamAnimationTick(_ timer: CADisplayLink) {
            guard streamAnimationEnabled else {
                stopStreamingAnimation(clearPending: false, normalizeTail: true)
                return
            }
            guard let textView = activeTextView else {
                stopStreamingAnimation(clearPending: false, normalizeTail: false)
                return
            }
            let elapsed = streamLastTimestamp > 0
                ? max(0, timer.timestamp - streamLastTimestamp)
                : (1.0 / 30.0)
            streamLastTimestamp = timer.timestamp

            if streamPauseRemaining > 0 {
                streamPauseRemaining = max(0, streamPauseRemaining - elapsed)
                if streamPauseRemaining > 0 {
                    return
                }
            }

            guard !pendingStreamingSuffix.isEmpty else {
                normalizeStreamingTailAppearance()
                streamTimer?.invalidate()
                streamTimer = nil
                streamLastTimestamp = 0
                streamCharacterBudget = 0
                return
            }

            let renderedCharacters = textView.textStorage.length
            streamCharacterBudget += elapsed * streamingCharactersPerSecond(
                for: pendingStreamingSuffix.count,
                renderedCharacters: renderedCharacters
            )
            let budgetStep = Int(streamCharacterBudget.rounded(.down))
            let step = adaptiveStreamingStep(
                budgetStep: budgetStep,
                pendingCharacters: pendingStreamingSuffix.count,
                renderedCharacters: renderedCharacters
            )
            streamCharacterBudget = max(0, streamCharacterBudget - Double(step))
            let chunk = consumeStreamingPrefix(maxCharacters: step)
            guard !chunk.isEmpty else { return }

            autoreleasepool {
                let storage = textView.textStorage
                removeStreamingCursorIfNeeded(in: storage)
                let appended = NSMutableAttributedString(string: chunk, attributes: streamAttributes)
                storage.beginEditing()
                storage.append(appended)
                applyStreamingTailFade(in: storage)
                storage.endEditing()
            }
            streamPauseRemaining = punctuationPauseDuration(
                after: chunk,
                renderedCharacters: renderedCharacters + chunk.count
            )
        }

        private func consumeStreamingPrefix(maxCharacters: Int) -> String {
            guard maxCharacters > 0, !pendingStreamingSuffix.isEmpty else { return "" }
            let lookahead = 12
            let end = pendingStreamingSuffix.index(
                pendingStreamingSuffix.startIndex,
                offsetBy: min(pendingStreamingSuffix.count, maxCharacters + lookahead),
                limitedBy: pendingStreamingSuffix.endIndex
            ) ?? pendingStreamingSuffix.endIndex
            let candidate = String(pendingStreamingSuffix[..<end])
            let minBreakDistance = min(8, maxCharacters)

            if let newlineIndex = candidate.firstIndex(of: "\n"),
               candidate.distance(from: candidate.startIndex, to: newlineIndex) >= minBreakDistance {
                let chunkEnd = pendingStreamingSuffix.index(
                    pendingStreamingSuffix.startIndex,
                    offsetBy: candidate.distance(from: candidate.startIndex, to: candidate.index(after: newlineIndex))
                )
                let prefix = String(pendingStreamingSuffix[..<chunkEnd])
                pendingStreamingSuffix.removeSubrange(..<chunkEnd)
                return prefix
            }

            let breakScalars = CharacterSet(charactersIn: "。！？!?；;，,、：:")
            var preferredIndex: String.Index?
            for index in candidate.indices.reversed() {
                let distance = candidate.distance(from: candidate.startIndex, to: index)
                guard distance >= minBreakDistance else { break }
                let scalars = candidate[index].unicodeScalars
                if scalars.allSatisfy({ breakScalars.contains($0) }) {
                    preferredIndex = candidate.index(after: index)
                    break
                }
            }

            if let preferredIndex {
                let length = candidate.distance(from: candidate.startIndex, to: preferredIndex)
                let chunkEnd = pendingStreamingSuffix.index(pendingStreamingSuffix.startIndex, offsetBy: length)
                let prefix = String(pendingStreamingSuffix[..<chunkEnd])
                pendingStreamingSuffix.removeSubrange(..<chunkEnd)
                return prefix
            }

            let fallbackEnd = pendingStreamingSuffix.index(
                pendingStreamingSuffix.startIndex,
                offsetBy: min(maxCharacters, pendingStreamingSuffix.count),
                limitedBy: pendingStreamingSuffix.endIndex
            ) ?? pendingStreamingSuffix.endIndex
            let prefix = String(pendingStreamingSuffix[..<fallbackEnd])
            pendingStreamingSuffix.removeSubrange(..<fallbackEnd)
            return prefix
        }

        private func adaptiveStreamingStep(
            budgetStep: Int,
            pendingCharacters: Int,
            renderedCharacters: Int
        ) -> Int {
            let maximum: Int
            if renderedCharacters < 18 {
                maximum = 10
            } else {
                switch pendingCharacters {
                case 4_000...:
                    maximum = 12
                case 1_200...:
                    maximum = 10
                case 320...:
                    maximum = 8
                default:
                    maximum = 6
                }
            }

            let minimum = renderedCharacters < 18 ? 2 : 1
            return max(minimum, min(maximum, max(1, budgetStep)))
        }

        private func streamingCharactersPerSecond(for pendingCharacters: Int, renderedCharacters: Int) -> Double {
            if renderedCharacters < 18 {
                return 138
            }
            if renderedCharacters < 48 {
                return 104
            }

            switch pendingCharacters {
            case 6_000...:
                return 82
            case 3_000...:
                return 72
            case 1_600...:
                return 62
            case 800...:
                return 54
            case 320...:
                return 46
            case 120...:
                return 38
            default:
                return 32
            }
        }

        private func punctuationPauseDuration(after chunk: String, renderedCharacters: Int) -> CFTimeInterval {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tail = trimmed.last else { return 0 }

            let inFastStart = renderedCharacters < 24
            switch tail {
            case "。", "！", "？", ".", "!", "?":
                return inFastStart ? 0.03 : 0.11
            case "，", ",", "；", ";", "：", ":", "、":
                return inFastStart ? 0.015 : 0.07
            default:
                return 0
            }
        }

        private func applyStreamingTailFade(in storage: NSTextStorage) {
            if let previous = lastStreamingTailRange,
               previous.location != NSNotFound,
               NSMaxRange(previous) <= storage.length {
                storage.addAttribute(.foregroundColor, value: streamPrimaryColor, range: previous)
            }

            guard storage.length > 0 else {
                lastStreamingTailRange = nil
                return
            }

            // Keep the newest two characters slightly hidden; each tick reveals
            // the previous tail and makes the stream feel less cursor-driven.
            let tailCount = min(2, max(1, storage.length))
            let tailRange = NSRange(location: storage.length - tailCount, length: tailCount)
            let alphas: [CGFloat]
            switch tailCount {
            case 1:
                alphas = [0.42]
            default:
                alphas = [0.78, 0.42]
            }

            for offset in 0..<tailRange.length {
                let alpha = alphas[offset]
                let color = streamPrimaryColor.withAlphaComponent(alpha)
                storage.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: NSRange(location: tailRange.location + offset, length: 1)
                )
            }

            lastStreamingTailRange = tailRange
        }

        private func normalizeStreamingTailAppearance() {
            guard let textView = activeTextView else {
                lastStreamingTailRange = nil
                lastStreamingCursorRange = nil
                return
            }
            removeStreamingCursorIfNeeded(in: textView.textStorage)
            guard let tailRange = lastStreamingTailRange,
                  tailRange.location != NSNotFound,
                  NSMaxRange(tailRange) <= textView.textStorage.length else {
                lastStreamingTailRange = nil
                return
            }

            textView.textStorage.beginEditing()
            textView.textStorage.addAttribute(.foregroundColor, value: streamPrimaryColor, range: tailRange)
            textView.textStorage.endEditing()
            lastStreamingTailRange = nil
        }

        private func removeStreamingCursorIfNeeded(in storage: NSTextStorage) {
            guard let cursorRange = lastStreamingCursorRange,
                  cursorRange.location != NSNotFound,
                  NSMaxRange(cursorRange) <= storage.length else {
                lastStreamingCursorRange = nil
                return
            }
            storage.deleteCharacters(in: cursorRange)
            lastStreamingCursorRange = nil
        }

        func cachedSizeIfAvailable(forWidth width: CGFloat, textCount: Int, lineBreakCount: Int) -> CGSize? {
            guard lastStreamingAnimated else { return nil }
            guard lastMeasuredHeight > 0 else { return nil }
            guard abs(width - lastMeasuredWidth) < 0.5 else { return nil }
            guard textCount >= lastMeasuredTextCount else { return nil }
            // Long responses need exact relayout; stale cached heights can cause overlap and wrong scroll range.
            guard textCount < 3_000 else { return nil }
            guard lineBreakCount < 20 else { return nil }
            guard lineBreakCount <= lastMeasuredLineBreakCount else { return nil }

            let delta = textCount - lastMeasuredTextCount
            let reuseThreshold: Int
            if textCount >= 2_000 {
                reuseThreshold = 6
            } else if textCount >= 1_000 {
                reuseThreshold = 4
            } else {
                reuseThreshold = 3
            }
            if delta < reuseThreshold {
                return CGSize(width: width, height: lastMeasuredHeight)
            }
            return nil
        }

        func recordMeasuredSize(_ size: CGSize, width: CGFloat, textCount: Int, lineBreakCount: Int) {
            lastMeasuredWidth = width
            lastMeasuredHeight = size.height
            lastMeasuredTextCount = textCount
            lastMeasuredLineBreakCount = lineBreakCount
        }
    }

    private static func markdownAttributedText(
        text: String,
        textColor: UIColor,
        linkColor: UIColor,
        font: UIFont
    ) -> NSAttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NSAttributedString() }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4.8
        paragraph.paragraphSpacing = 8
        let fallbackAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        if #available(iOS 15.0, *) {
            do {
                let attributed = try AttributedString(
                    markdown: trimmed,
                    options: AttributedString.MarkdownParsingOptions(
                        interpretedSyntax: .full,
                        failurePolicy: .returnPartiallyParsedIfPossible
                    )
                )
                let output = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
                let fullRange = NSRange(location: 0, length: output.length)

                output.addAttribute(.foregroundColor, value: textColor, range: fullRange)
                output.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
                // Keep all assistant text in a unified regular weight.
                output.addAttribute(.font, value: font, range: fullRange)

                let renderedText = output.string
                if Self.shouldRunURLLinkDetection(for: renderedText),
                   let detector = Self.linkDetector {
                    let nsRendered = renderedText as NSString
                    let detectRange = NSRange(location: 0, length: nsRendered.length)
                    detector.enumerateMatches(in: renderedText, options: [], range: detectRange) { match, _, _ in
                        guard let match, let url = match.url else { return }
                        output.addAttributes(
                            [
                                .link: url,
                                .foregroundColor: linkColor,
                                .underlineStyle: 0
                            ],
                            range: match.range
                        )
                    }
                }
                if Self.shouldRunProjectPathLinkDetection(for: output.string) {
                    Self.addProjectPathLinks(
                        to: output,
                        sourceText: output.string,
                        linkColor: linkColor
                    )
                }

                return output
            } catch {
                let fallback = NSMutableAttributedString(string: trimmed, attributes: fallbackAttributes)
                if Self.shouldRunProjectPathLinkDetection(for: trimmed) {
                    Self.addProjectPathLinks(
                        to: fallback,
                        sourceText: trimmed,
                        linkColor: linkColor
                    )
                }
                return fallback
            }
        }

        let fallback = NSMutableAttributedString(string: trimmed, attributes: fallbackAttributes)
        if Self.shouldRunProjectPathLinkDetection(for: trimmed) {
            Self.addProjectPathLinks(
                to: fallback,
                sourceText: trimmed,
                linkColor: linkColor
            )
        }
        return fallback
    }

    private static func shouldRunURLLinkDetection(for text: String) -> Bool {
        text.count <= maxURLLinkDetectionCharacters
    }

    private static func shouldRunProjectPathLinkDetection(for text: String) -> Bool {
        guard text.count <= maxProjectPathLinkDetectionCharacters else { return false }
        let lowered = text.lowercased()
        if lowered.contains("/") {
            return true
        }
        let hints = [
            ".swift", ".py", ".js", ".ts", ".tsx", ".jsx",
            ".c", ".h", ".hpp", ".cpp", ".go", ".rs", ".java", ".kt",
            ".php", ".rb", ".lua", ".sql", ".md", ".txt",
            "cmakelists", "dockerfile", "makefile",
            "package.json", "requirements.txt", "cargo.toml", "go.mod", "readme"
        ]
        return hints.contains(where: { lowered.contains($0) })
    }

    private static func addProjectPathLinks(
        to attributed: NSMutableAttributedString,
        sourceText: String,
        linkColor: UIColor
    ) {
        guard !sourceText.isEmpty else { return }
        guard let regex = projectPathRegex else { return }
        let nsText = sourceText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        regex.enumerateMatches(in: sourceText, options: [], range: fullRange) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let pathRange = match.range(at: 1)
            guard pathRange.location != NSNotFound, pathRange.length > 0 else { return }
            guard pathRange.location < attributed.length else { return }
            guard attributed.attribute(.link, at: pathRange.location, effectiveRange: nil) == nil else { return }

            let rawCandidate = nsText.substring(with: pathRange)
            guard let normalizedPath = normalizedProjectPathCandidate(rawCandidate) else { return }
            guard let encodedPath = normalizedPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "\(fileLinkScheme)://open?path=\(encodedPath)") else {
                return
            }

            attributed.addAttributes(
                [
                    .link: url,
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: pathRange
            )
        }
    }

    private static func normalizedProjectPathCandidate(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>"))
        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("./") {
            value.removeFirst(2)
        }
        guard !value.isEmpty else { return nil }
        guard !value.hasPrefix("../"), !value.hasPrefix("/") else { return nil }
        guard !value.contains("://") else { return nil }
        guard value.range(of: #"^[A-Za-z0-9._/\-]+$"#, options: .regularExpression) != nil else { return nil }

        let lowered = value.lowercased()
        if pathLikeFileNames.contains(lowered) {
            return value
        }

        let fileName = (lowered as NSString).lastPathComponent
        if pathLikeFileNames.contains(fileName) {
            return value
        }

        guard let dot = fileName.lastIndex(of: ".") else { return nil }
        let ext = String(fileName[fileName.index(after: dot)...])
        guard pathLikeExtensions.contains(ext) else { return nil }
        return value
    }

    private static func filePath(fromProjectLink url: URL) -> String? {
        guard url.scheme?.lowercased() == fileLinkScheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value else {
            return nil
        }

        let normalized = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func applyHeadingTypography(
        to attributed: NSMutableAttributedString,
        sourceMarkdown: String,
        baseFont: UIFont,
        textColor: UIColor
    ) {
        let headings = markdownHeadings(from: sourceMarkdown)
        guard !headings.isEmpty else { return }

        let rendered = attributed.string as NSString
        var searchStart = 0

        for heading in headings {
            guard !heading.title.isEmpty else { continue }
            let searchRange = NSRange(
                location: searchStart,
                length: max(0, rendered.length - searchStart)
            )
            guard searchRange.length > 0 else { break }

            let found = rendered.range(of: heading.title, options: [], range: searchRange)
            guard found.location != NSNotFound else { continue }

            let paragraphRange = rendered.paragraphRange(for: found)
            let headingFont = UIFont.systemFont(
                ofSize: headingFontSize(level: heading.level, baseSize: baseFont.pointSize),
                weight: .semibold
            )
            let headingParagraph = NSMutableParagraphStyle()
            headingParagraph.lineSpacing = 3.5
            headingParagraph.paragraphSpacing = heading.level <= 2 ? 12 : 9
            headingParagraph.paragraphSpacingBefore = heading.level <= 2 ? 10 : 8

            attributed.addAttributes(
                [
                    .font: headingFont,
                    .foregroundColor: textColor,
                    .paragraphStyle: headingParagraph
                ],
                range: paragraphRange
            )
            searchStart = paragraphRange.location + paragraphRange.length
        }
    }

    private static func markdownHeadings(from source: String) -> [(level: Int, title: String)] {
        let lines = source.components(separatedBy: "\n")
        var results: [(Int, String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }

            var level = 0
            for character in trimmed {
                if character == "#" {
                    level += 1
                } else {
                    break
                }
            }

            guard level > 0, level <= 6 else { continue }
            let title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            results.append((level, title))
        }
        return results
    }

    private static func headingFontSize(level: Int, baseSize: CGFloat) -> CGFloat {
        let baseline = max(baseSize, 16)
        switch level {
        case 1:
            return baseline + 8
        case 2:
            return baseline + 5
        case 3:
            return baseline + 3
        case 4:
            return baseline + 2
        case 5:
            return baseline + 1
        default:
            return baseline
        }
    }
}
