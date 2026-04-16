import SwiftUI
import UIKit

struct SelectableLinkTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var linkColor: UIColor = .secondaryLabel
    var font: UIFont = .systemFont(ofSize: 17, weight: .regular)
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
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
        // Let the parent SwiftUI ScrollView own vertical scrolling.
        view.panGestureRecognizer.isEnabled = false
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let shouldRebuildText =
            coordinator.lastText != text
            || coordinator.lastFontPointSize != font.pointSize
            || !coordinator.lastTextColor.isEqual(textColor)
            || !coordinator.lastLinkColor.isEqual(linkColor)
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

        uiView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: 0
        ]
        uiView.attributedText = attributed
        coordinator.lastText = text
        coordinator.lastFontPointSize = font.pointSize
        coordinator.lastTextColor = textColor
        coordinator.lastLinkColor = linkColor
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
}
