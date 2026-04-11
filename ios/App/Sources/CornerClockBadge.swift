import SwiftUI

struct CornerClockBadge: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE M月d日 HH:mm"
        return f
    }()

    var body: some View {
        Text(Self.formatter.string(from: now))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.9))
            )
            .lineLimit(1)
            .onReceive(timer) { value in
                now = value
            }
    }
}
