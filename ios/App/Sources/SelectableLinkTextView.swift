import SwiftUI
import UIKit

struct SelectableLinkTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var linkColor: UIColor = .secondaryLabel
    var font: UIFont = UIFont(name: "PingFangSC-Regular", size: 15.5) ?? .systemFont(ofSize: 15.5, weight: .regular)
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
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
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
            let forceImmediateRebuild = !streamingAnimated && coordinator.lastStreamingAnimated
            if fullTextChangedShape || forceImmediateRebuild {
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
        private var streamCharacterBudget: Double = 0
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
            if clearPending {
                pendingStreamingSuffix.removeAll(keepingCapacity: false)
            }
        }

        private func startStreamingAnimationIfNeeded() {
            guard streamTimer == nil else { return }
            let timer = CADisplayLink(target: self, selector: #selector(handleStreamAnimationTick(_:)))
            if #available(iOS 15.0, *) {
                timer.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 45, preferred: 45)
            } else {
                timer.preferredFramesPerSecond = 45
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
            guard !pendingStreamingSuffix.isEmpty else {
                // Keep current tail fade while waiting for the next chunk to avoid flashing.
                stopStreamingAnimation(clearPending: false, normalizeTail: false)
                return
            }

            let elapsed = streamLastTimestamp > 0
                ? max(0, timer.timestamp - streamLastTimestamp)
                : (1.0 / 45.0)
            streamLastTimestamp = timer.timestamp

            streamCharacterBudget += elapsed * streamingCharactersPerSecond(for: pendingStreamingSuffix.count)
            let budgetStep = Int(streamCharacterBudget.rounded(.down))
            let step = max(1, min(6, budgetStep))
            streamCharacterBudget = max(0, streamCharacterBudget - Double(step))
            let chunk = consumeStreamingPrefix(maxCharacters: step)
            guard !chunk.isEmpty else { return }

            autoreleasepool {
                let storage = textView.textStorage
                let appended = NSMutableAttributedString(string: chunk, attributes: streamAttributes)
                storage.beginEditing()
                storage.append(appended)
                applyStreamingTailFade(in: storage)
                storage.endEditing()
            }
        }

        private func consumeStreamingPrefix(maxCharacters: Int) -> String {
            guard maxCharacters > 0, !pendingStreamingSuffix.isEmpty else { return "" }
            let end = pendingStreamingSuffix.index(
                pendingStreamingSuffix.startIndex,
                offsetBy: maxCharacters,
                limitedBy: pendingStreamingSuffix.endIndex
            ) ?? pendingStreamingSuffix.endIndex
            let prefix = String(pendingStreamingSuffix[..<end])
            pendingStreamingSuffix.removeSubrange(..<end)
            return prefix
        }

        private func streamingCharactersPerSecond(for pendingCharacters: Int) -> Double {
            switch pendingCharacters {
            case 6_000...:
                return 420
            case 3_000...:
                return 320
            case 1_600...:
                return 250
            case 800...:
                return 190
            case 320...:
                return 140
            case 120...:
                return 100
            default:
                return 72
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

            // Use a tiny trailing window so the newest character looks subtly lighter
            // without repainting a large range each frame (which can look like flicker).
            let tailCount = min(3, max(1, storage.length))
            let tailRange = NSRange(location: storage.length - tailCount, length: tailCount)
            let alphas: [CGFloat]
            switch tailCount {
            case 1:
                alphas = [0.58]
            case 2:
                alphas = [0.82, 0.58]
            default:
                alphas = [0.92, 0.78, 0.58]
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
                return
            }
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
