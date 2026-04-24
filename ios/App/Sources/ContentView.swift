import SwiftUI
import UIKit

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
        .onAppear {
            applyWindowThemeBackground()
        }
        .onChange(of: viewModel.preferredColorScheme) { _, _ in
            applyWindowThemeBackground()
        }
    }

    private func applyWindowThemeBackground() {
        let color = MinisTheme.appBackgroundUIColor
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in windowScenes {
            for window in scene.windows {
                window.backgroundColor = color
                window.rootViewController?.view.backgroundColor = color
                window.rootViewController?.view.isOpaque = false
            }
        }
    }
}
