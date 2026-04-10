import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

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
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.content.isEmpty && message.isStreaming ? "正在接收流式内容…" : message.content)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            if message.isStreaming {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color)
        )
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
