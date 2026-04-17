import Foundation
import UIKit

/// Markdown is intentionally delayed until stream completion.
/// This protocol keeps post-processing extensible.
protocol MarkdownPostProcessing {
    func render(markdown: String, baseFont: UIFont, textColor: UIColor) -> NSAttributedString
}

struct DeferredMarkdownPostProcessor: MarkdownPostProcessing {
    func render(markdown: String, baseFont: UIFont, textColor: UIColor) -> NSAttributedString {
        let input = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return NSAttributedString() }

        if #available(iOS 15.0, *) {
            do {
                let attributed = try AttributedString(
                    markdown: input,
                    options: AttributedString.MarkdownParsingOptions(
                        interpretedSyntax: .full,
                        failurePolicy: .returnPartiallyParsedIfPossible
                    )
                )
                let output = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
                let fullRange = NSRange(location: 0, length: output.length)

                output.addAttribute(.foregroundColor, value: textColor, range: fullRange)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 4
                paragraph.paragraphSpacing = 6
                output.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

                // Keep parser-produced styles; fallback font for runs without font.
                output.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                    if value == nil {
                        output.addAttribute(.font, value: baseFont, range: range)
                    }
                }
                return output
            } catch {
                return NSAttributedString(
                    string: input,
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: textColor
                    ]
                )
            }
        }

        return NSAttributedString(
            string: input,
            attributes: [
                .font: baseFont,
                .foregroundColor: textColor
            ]
        )
    }
}

