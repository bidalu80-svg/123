import SwiftUI
import UIKit

struct MessageBubbleView: View {
    let message: ChatMessage
    let codeThemeMode: CodeThemeMode
    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedToast = false

    var body: some View {
        VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 6) {
            roleTag

            HStack {
                if message.role == .assistant {
                    bubbleBody
                    Spacer(minLength: 34)
                } else {
                    Spacer(minLength: 34)
                    bubbleBody
                }
            }
        }
    }

    private var roleTag: some View {
        Text(roleTitle)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(roleTitle == "IEXA" ? Color.blue.opacity(0.12) : Color.green.opacity(0.16))
            )
            .foregroundStyle(.secondary)
    }

    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            content

            if message.isStreaming {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button("复制全部") {
                    UIPasteboard.general.string = message.copyableText
                    showCopyToast()
                }
                .font(.caption2)
                .buttonStyle(.bordered)

                if copiedToast {
                    Text("复制完成")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(message.role == .assistant ? Color(.secondarySystemBackground) : Color.blue.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        let segments = MessageContentParser.parse(message)
        if segments.isEmpty && message.isStreaming {
            Text("正在接收流式内容…")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .code(let language, let content):
            codeBlock(title: (language ?? "code").uppercased(), content: content)
        case .file(let name, let language, let content):
            codeBlock(title: "FILE · \(name)", content: content, language: language)
        case .image(let attachment):
            messageImage(attachment)
        }
    }

    private func codeBlock(title: String, content: String, language: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制代码") {
                    UIPasteboard.general.string = content
                    showCopyToast()
                }
                .font(.caption2)
                .buttonStyle(.bordered)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlighted(content, language: language, colorScheme: colorScheme, codeThemeMode: codeThemeMode))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(codeBackgroundColor)
        )
    }

    @ViewBuilder
    private func messageImage(_ attachment: ChatImageAttachment) -> some View {
        if let data = attachment.decodedImageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contextMenu {
                    Button("复制图片链接") {
                        UIPasteboard.general.string = attachment.requestURLString
                        showCopyToast()
                    }
                }
        } else if let urlString = attachment.renderURLString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
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
            .contextMenu {
                Button("复制图片链接") {
                    UIPasteboard.general.string = attachment.requestURLString
                    showCopyToast()
                }
            }
        }
    }

    private func showCopyToast() {
        copiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            copiedToast = false
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .user:
            return "USER"
        case .assistant:
            return "IEXA"
        case .system:
            return "SYSTEM"
        }
    }

    private var codeBackgroundColor: Color {
        switch codeThemeMode {
        case .vscodeDark:
            return Color(red: 0.12, green: 0.12, blue: 0.12)
        case .githubLight:
            return Color(red: 0.96, green: 0.97, blue: 0.99)
        case .followApp:
            return colorScheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color(red: 0.96, green: 0.97, blue: 0.99)
        }
    }
}
