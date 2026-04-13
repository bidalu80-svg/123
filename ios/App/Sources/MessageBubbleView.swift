import SwiftUI
import UIKit
import Photos

struct MessageBubbleView: View {
    let message: ChatMessage
    let codeThemeMode: CodeThemeMode
    let apiKey: String
    let apiBaseURL: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var saveFeedback: String?

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
        .alert("提示", isPresented: saveFeedbackBinding) {
            Button("确定", role: .cancel) {
                saveFeedback = nil
            }
        } message: {
            Text(saveFeedback ?? "")
        }
    }

    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 0) {
            content

            if message.isStreaming {
                ProgressView()
                    .scaleEffect(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userMessageView: some View {
        HStack {
            Spacer(minLength: 68)
            userMessageContent
                .padding(.vertical, 13)
                .padding(.horizontal, 17)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(userBubbleColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.035), lineWidth: 0.8)
                )
                .frame(maxWidth: 290, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var userMessageContent: some View {
        let segments = MessageContentParser.parse(message)
        if segments.isEmpty && message.isStreaming {
            Text("正在发送…")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    userSegmentView(segment)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
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
    private func userSegmentView(_ segment: MessageSegment) -> some View {
        switch segment {
        case .text(let text):
            SelectableLinkTextView(
                text: text,
                font: .systemFont(ofSize: 18, weight: .regular)
            )
        case .code(let language, let content):
            codeBlock(title: (language ?? "code").uppercased(), content: content)
        case .file(let name, let language, let content):
            codeBlock(title: "FILE · \(name)", content: content, language: language)
        case .image(let attachment):
            messageImage(attachment)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment) -> some View {
        switch segment {
        case .text(let text):
            SelectableLinkTextView(
                text: text,
                font: .systemFont(ofSize: 18, weight: .regular)
            )
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
            renderedMessageImage(Image(uiImage: uiImage), attachment: attachment)
        } else if let urlString = attachment.renderURLString {
            renderedMessageImage(
                RemoteImageView(urlString: urlString, apiKey: apiKey, baseURL: apiBaseURL),
                attachment: attachment
            )
        }
    }

    private func renderedMessageImage<V: View>(_ imageView: V, attachment: ChatImageAttachment) -> some View {
        imageView
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 260, maxHeight: 560)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                if !attachment.requestURLString.isEmpty {
                    Button("复制图片链接") {
                        UIPasteboard.general.string = attachment.requestURLString
                    }
                }
                Button("保存到相册") {
                    saveImageAttachment(attachment)
                }
            }
    }

    private func renderedRemoteImage(_ urlString: String, attachment: ChatImageAttachment) -> some View {
        RemoteImageView(urlString: urlString)
            .frame(maxWidth: 260, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                if !attachment.requestURLString.isEmpty {
                    Button("复制图片链接") {
                        UIPasteboard.general.string = attachment.requestURLString
                    }
                }
                Button("保存到相册") {
                    saveImageAttachment(attachment)
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
        colorScheme == .dark ? Color(red: 0.18, green: 0.18, blue: 0.2) : Color(red: 0.94, green: 0.94, blue: 0.95)
    }

    private var saveFeedbackBinding: Binding<Bool> {
        Binding(
            get: { saveFeedback != nil },
            set: { newValue in
                if !newValue {
                    saveFeedback = nil
                }
            }
        )
    }

    private func saveImageAttachment(_ attachment: ChatImageAttachment) {
        if let data = attachment.decodedImageData, let image = UIImage(data: data) {
            writeImageToPhotos(image)
            return
        }

        guard let urlString = attachment.renderURLString,
              let resolved = normalizedRemoteURLString(urlString),
              let url = URL(string: resolved) else {
            saveFeedback = "当前图片无法保存。"
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else {
                    await MainActor.run {
                        saveFeedback = "图片保存失败。"
                    }
                    return
                }
                await MainActor.run {
                    writeImageToPhotos(image)
                }
            } catch {
                await MainActor.run {
                    saveFeedback = "图片保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func writeImageToPhotos(_ image: UIImage) {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            UIImageWriteToSavedPhotosAlbum(image, ImageSaveCoordinator.shared, #selector(ImageSaveCoordinator.handleSaveResult(_:didFinishSavingWithError:contextInfo:)), nil)
            ImageSaveCoordinator.shared.onComplete = { error in
                saveFeedback = error == nil ? "已保存到相册。" : "图片保存失败：\(error?.localizedDescription ?? "未知错误")"
            }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                Task { @MainActor in
                    if status == .authorized || status == .limited {
                        writeImageToPhotos(image)
                    } else {
                        saveFeedback = "没有相册写入权限。"
                    }
                }
            }
        default:
            saveFeedback = "没有相册写入权限。"
        }
    }

    private func normalizedRemoteURLString(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        cleaned = cleaned.replacingOccurrences(of: "\\/", with: "/")
        cleaned = cleaned.replacingOccurrences(of: "&amp;", with: "&")
        if cleaned.hasPrefix("//") {
            cleaned = "https:\(cleaned)"
        }
        if cleaned.hasPrefix("/") {
            let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !base.isEmpty {
                cleaned = "\(base)\(cleaned)"
            }
        }
        if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") {
            return cleaned
        }
        return nil
    }
}

private final class ImageSaveCoordinator: NSObject {
    static let shared = ImageSaveCoordinator()
    var onComplete: ((Error?) -> Void)?

    @objc func handleSaveResult(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        onComplete?(error)
        onComplete = nil
    }
}
