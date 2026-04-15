import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var authViewModel: AuthViewModel

    var body: some View {
        NavigationStack {
            if authViewModel.isAuthenticated {
                ChatScreen()
            } else {
                AuthScreen()
            }
        }
        .tint(.primary)
        .preferredColorScheme(viewModel.preferredColorScheme)
    }
}
