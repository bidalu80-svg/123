import SwiftUI
import UIKit

struct SelectableLinkTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var linkColor: UIColor = .secondaryLabel
    var font: UIFont = .systemFont(ofSize: 17, weight: .regular)
    var renderMarkdown: Bool = false
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
        if !shouldRebuildText {
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        if renderMarkdown {
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
            coordinator.markdownRenderToken &+= 1
            coordinator.lastMarkdownSource = ""
            coordinator.cachedMarkdown = nil
            coordinator.lastMarkdownFontPointSize = 0
            coordinator.lastMarkdownTextColor = .clear
            coordinator.lastMarkdownLinkColor = .clear

            let fullTextChangedShape = coordinator.lastText.isEmpty || !text.hasPrefix(coordinator.lastText)
            if fullTextChangedShape {
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
                                .underlineStyle: 0,
                                .font: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                            ],
                            range: match.range
                        )
                    }
                }
                uiView.attributedText = attributed
            } else {
                let suffix = String(text.dropFirst(coordinator.lastText.count))
                if !suffix.isEmpty {
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
                                    .underlineStyle: 0,
                                    .font: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                                ],
                                range: match.range
                            )
                        }
                    }
                    uiView.textStorage.append(appended)
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
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1 else { return nil }
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(target)
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastText: String = ""
        var lastFontPointSize: CGFloat = 0
        var lastTextColor: UIColor = .clear
        var lastLinkColor: UIColor = .clear
        var lastRenderMarkdown: Bool = false
        var markdownRenderToken: Int = 0
        var lastMarkdownSource: String = ""
        var cachedMarkdown: NSAttributedString?
        var lastMarkdownFontPointSize: CGFloat = 0
        var lastMarkdownTextColor: UIColor = .clear
        var lastMarkdownLinkColor: UIColor = .clear

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
        paragraph.lineSpacing = 4.5
        paragraph.paragraphSpacing = 10
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

                output.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                    if value == nil {
                        output.addAttribute(.font, value: font, range: range)
                    }
                }
                applyHeadingTypography(
                    to: output,
                    sourceMarkdown: trimmed,
                    baseFont: font,
                    textColor: textColor
                )

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
        let baseline = max(baseSize, 17)
        switch level {
        case 1:
            return baseline + 12
        case 2:
            return baseline + 8
        case 3:
            return baseline + 5
        case 4:
            return baseline + 3
        case 5:
            return baseline + 1.5
        default:
            return baseline + 0.5
        }
    }
}
