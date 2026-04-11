import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
            ChatScreen()
        }
        .tint(.primary)
        .preferredColorScheme(viewModel.preferredColorScheme)
    }
}
