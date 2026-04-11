import SwiftUI

struct CornerClockBadge: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.9))
            )
            .onReceive(timer) { value in
                now = value
            }
    }
}
