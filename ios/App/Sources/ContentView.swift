import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        TabView {
            NavigationStack {
                ChatScreen()
            }
            .tabItem {
                Label("聊天", systemImage: "message.fill")
            }

            NavigationStack {
                SettingsScreen()
            }
            .tabItem {
                Label("配置", systemImage: "gearshape.fill")
            }

            NavigationStack {
                TestCenterScreen()
            }
            .tabItem {
                Label("测试", systemImage: "checkmark.circle.fill")
            }
        }
        .tint(.blue)
        .preferredColorScheme(viewModel.preferredColorScheme)
        .overlay(alignment: .topTrailing) {
            CornerClockBadge()
                .padding(.top, 6)
                .padding(.trailing, 10)
        }
    }
}
