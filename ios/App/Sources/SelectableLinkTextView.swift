import SwiftUI
import UIKit

struct SelectableLinkTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var linkColor: UIColor = .secondaryLabel
    var font: UIFont = .systemFont(ofSize: 17, weight: .regular)

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
        view.adjustsFontForContentSizeCategory = true
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        let attributed = NSMutableAttributedString(string: text, attributes: attrs)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
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
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(target)
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
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
