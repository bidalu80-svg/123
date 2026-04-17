import SwiftUI
import UIKit

struct SelectableCodeTextView: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    var font: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var lineSpacing: CGFloat = 3

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.scrollsToTop = false
        view.backgroundColor = .clear
        view.dataDetectorTypes = []
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.textContainer.lineBreakMode = .byWordWrapping
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.panGestureRecognizer.isEnabled = true
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let shouldRebuild =
            coordinator.lastText != text
            || coordinator.lastLineSpacing != lineSpacing
            || coordinator.lastFontPointSize != font.pointSize
            || !coordinator.lastTextColor.isEqual(textColor)

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
            uiView.attributedText = NSAttributedString(string: text, attributes: attributes)
        } else {
            let suffix = String(text.dropFirst(coordinator.lastText.count))
            if !suffix.isEmpty {
                uiView.textStorage.append(NSAttributedString(string: suffix, attributes: attributes))
            }
        }

        coordinator.lastText = text
        coordinator.lastLineSpacing = lineSpacing
        coordinator.lastFontPointSize = font.pointSize
        coordinator.lastTextColor = textColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1 else { return nil }
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        let fitted = uiView.sizeThatFits(target)
        return CGSize(width: width, height: ceil(fitted.height))
    }

    final class Coordinator: NSObject {
        var lastText = ""
        var lastLineSpacing: CGFloat = 0
        var lastFontPointSize: CGFloat = 0
        var lastTextColor: UIColor = .clear
    }
}

