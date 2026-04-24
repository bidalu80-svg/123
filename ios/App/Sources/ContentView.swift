import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var authViewModel: AuthViewModel

    var body: some View {
        ZStack {
            MinisTheme.appBackground
                .ignoresSafeArea()

            NavigationStack {
                if authViewModel.isAuthenticated {
                    ChatScreen()
                } else {
                    AuthScreen()
                }
            }
            .background(MinisTheme.appBackground.ignoresSafeArea())
        }
        .tint(.primary)
        .preferredColorScheme(viewModel.preferredColorScheme)
    }
}
