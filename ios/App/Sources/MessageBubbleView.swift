import SwiftUI
import UIKit

struct MessageBubbleView: View {
    let message: ChatMessage
    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedToast = false

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble(alignment: .leading, color: Color.blue.opacity(0.12), textColor: .primary)
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble(alignment: .trailing, color: Color.green.opacity(0.18), textColor: .primary)
            }
        }
    }

    private func bubble(alignment: HorizontalAlignment, color: Color, textColor: Color) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制") {
                    UIPasteboard.general.string = message.copyableText
                    copiedToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copiedToast = false
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
            }

            content(alignment: alignment, textColor: textColor)

            if message.isStreaming {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            }
            if copiedToast {
                Text("已复制")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color)
        )
    }

    @ViewBuilder
    private func content(alignment: HorizontalAlignment, textColor: Color) -> some View {
        let segments = MessageContentParser.parse(message)
        if segments.isEmpty && message.isStreaming {
            Text("正在接收流式内容…")
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        } else {
            VStack(alignment: alignment, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment, alignment: alignment, textColor: textColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment, alignment: HorizontalAlignment, textColor: Color) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        case .code(let language, let content):
            codeBlock(language: language, content: content, alignment: alignment)
        case .image(let attachment):
            messageImage(attachment, alignment: alignment)
        }
    }

    private func codeBlock(language: String?, content: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制代码") {
                    UIPasteboard.general.string = content
                }
                .font(.caption2)
                .buttonStyle(.bordered)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlighted(content, language: language, colorScheme: colorScheme))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color(red: 0.96, green: 0.97, blue: 0.99))
        )
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    @ViewBuilder
    private func messageImage(_ attachment: ChatImageAttachment, alignment: HorizontalAlignment) -> some View {
        if let data = attachment.decodedImageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        } else if let urlString = attachment.renderURLString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .failure:
                    Text("图片加载失败")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        }
    }

    private var title: String {
        switch message.role {
        case .user:
            return "你"
        case .assistant:
            return "AI"
        case .system:
            return "系统"
        }
    }
}
