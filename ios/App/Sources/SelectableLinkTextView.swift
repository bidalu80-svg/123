import SwiftUI
import UIKit

struct SelectableLinkTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var linkColor: UIColor = .secondaryLabel
    var font: UIFont = UIFont(name: "PingFangSC-Regular", size: 15.5) ?? .systemFont(ofSize: 15.5, weight: .regular)
    var renderMarkdown: Bool = false
    var streamingAnimated: Bool = false
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let markdownRenderQueue = DispatchQueue(label: "chatapp.markdown.render", qos: .userInitiated)

    func makeCoordinator() -> Coordinator {
        Coordinator()
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
        view.layoutManager.allowsNonContiguousLayout = true
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
                    if let detector = Self.linkDetector {
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
                    uiView.attributedText = attributed
                }
            } else {
                let suffix = String(text.dropFirst(coordinator.lastText.count))
                if !suffix.isEmpty {
                    if streamingAnimated {
                        coordinator.queueStreamingSuffix(suffix)
                    } else {
                        let appended = NSMutableAttributedString(string: suffix, attributes: attrs)
                        if let detector = Self.linkDetector {
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
                        uiView.textStorage.append(appended)
                    }
                }
            }
        }

        uiView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: 0
        ]
        coordinator.lastText = text
        coordinator.lastFontPointSize = font.pointSize
        coordinator.lastTextColor = textColor
        coordinator.lastLinkColor = linkColor
        coordinator.lastRenderMarkdown = renderMarkdown
        coordinator.lastStreamingAnimated = streamingAnimated
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1 else { return nil }
        if let cached = context.coordinator.cachedSizeIfAvailable(forWidth: width, textCount: text.count) {
            return cached
        }
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(target)
        let fitted = CGSize(width: width, height: ceil(size.height))
        context.coordinator.recordMeasuredSize(fitted, width: width, textCount: text.count)
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

        deinit {
            stopStreamingAnimation(clearPending: true)
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
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

        func stopStreamingAnimation(clearPending: Bool) {
            normalizeStreamingTailAppearance()
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
                timer.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            } else {
                timer.preferredFramesPerSecond = 60
            }
            timer.add(to: .main, forMode: .common)
            streamTimer = timer
            streamLastTimestamp = 0
        }

        @objc
        private func handleStreamAnimationTick(_ timer: CADisplayLink) {
            guard streamAnimationEnabled else {
                stopStreamingAnimation(clearPending: false)
                return
            }
            guard let textView = activeTextView else {
                stopStreamingAnimation(clearPending: false)
                return
            }
            guard !pendingStreamingSuffix.isEmpty else {
                stopStreamingAnimation(clearPending: false)
                return
            }

            let elapsed = streamLastTimestamp > 0
                ? max(0, timer.timestamp - streamLastTimestamp)
                : (1.0 / 60.0)
            streamLastTimestamp = timer.timestamp

            streamCharacterBudget += elapsed * streamingCharactersPerSecond(for: pendingStreamingSuffix.count)
            let budgetStep = Int(streamCharacterBudget.rounded(.down))
            let step = max(1, min(12, budgetStep))
            streamCharacterBudget = max(0, streamCharacterBudget - Double(step))
            let chunk = consumeStreamingPrefix(maxCharacters: step)
            guard !chunk.isEmpty else { return }

            autoreleasepool {
                let storage = textView.textStorage
                let appended = NSMutableAttributedString(string: chunk, attributes: streamAttributes)
                let appendedLength = appended.length
                storage.beginEditing()
                storage.append(appended)
                applyStreamingTailFade(in: storage, appendedLength: appendedLength)
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
                return 520
            case 3_000...:
                return 380
            case 1_600...:
                return 280
            case 800...:
                return 210
            case 320...:
                return 150
            case 120...:
                return 110
            default:
                return 72
            }
        }

        private func applyStreamingTailFade(in storage: NSTextStorage, appendedLength: Int) {
            if let previous = lastStreamingTailRange,
               previous.location != NSNotFound,
               NSMaxRange(previous) <= storage.length {
                storage.addAttribute(.foregroundColor, value: streamPrimaryColor, range: previous)
            }

            guard storage.length > 0 else {
                lastStreamingTailRange = nil
                return
            }

            let tailSize = min(max(10, appendedLength * 5), 30)
            let start = max(0, storage.length - tailSize)
            let tailRange = NSRange(location: start, length: storage.length - start)
            if tailRange.length > 0 {
                for offset in 0..<tailRange.length {
                    let unit = tailRange.length <= 1 ? 1.0 : (Double(offset) / Double(tailRange.length - 1))
                    let alpha = CGFloat(1.0 - (0.58 * unit))
                    let color = streamPrimaryColor.withAlphaComponent(alpha)
                    storage.addAttribute(
                        .foregroundColor,
                        value: color,
                        range: NSRange(location: tailRange.location + offset, length: 1)
                    )
                }

                let latestCount = min(1, tailRange.length)
                if latestCount > 0 {
                    let latestRange = NSRange(location: storage.length - latestCount, length: latestCount)
                    let latestColor = streamPrimaryColor.withAlphaComponent(0.28)
                    storage.addAttribute(.foregroundColor, value: latestColor, range: latestRange)
                }
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

        func cachedSizeIfAvailable(forWidth width: CGFloat, textCount: Int) -> CGSize? {
            guard lastStreamingAnimated else { return nil }
            guard lastMeasuredHeight > 0 else { return nil }
            guard abs(width - lastMeasuredWidth) < 0.5 else { return nil }
            guard textCount >= lastMeasuredTextCount else { return nil }

            let delta = textCount - lastMeasuredTextCount
            if delta < 20 {
                return CGSize(width: width, height: lastMeasuredHeight)
            }
            return nil
        }

        func recordMeasuredSize(_ size: CGSize, width: CGFloat, textCount: Int) {
            lastMeasuredWidth = width
            lastMeasuredHeight = size.height
            lastMeasuredTextCount = textCount
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

                if let detector = Self.linkDetector {
                    let renderedText = output.string
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

                return output
            } catch {
                return NSAttributedString(string: trimmed, attributes: fallbackAttributes)
            }
        }

        return NSAttributedString(string: trimmed, attributes: fallbackAttributes)
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
