import SwiftUI
import UIKit

struct MessageBubbleView: View {
    let message: ChatMessage
    let codeThemeMode: CodeThemeMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if message.role == .user {
                userMessageView
            } else {
                assistantMessageView
            }
        }
        .contextMenu {
            Button("复制全部") {
                UIPasteboard.general.string = message.copyableText
            }
        }
    }

    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 0) {
            content

            if message.isStreaming {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }

            Divider()
                .opacity(0.26)
                .padding(.top, 14)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userMessageView: some View {
        HStack {
            Spacer(minLength: 38)
            content
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(userBubbleColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(colorScheme == .dark ? 0.2 : 0.05), lineWidth: 0.8)
                )
                .frame(maxWidth: 280, alignment: .trailing)
        }
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
            SelectableLinkTextView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                }
            }
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

    private var userBubbleColor: Color {
        colorScheme == .dark ? Color(red: 0.2, green: 0.2, blue: 0.22) : Color(red: 0.94, green: 0.94, blue: 0.95)
    }
}
