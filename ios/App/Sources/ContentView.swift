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
            .onOpenURL { url in
                handleIncomingURL(url)
            }
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
                window.rootViewController?.view.isOpaque = true
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        guard (components.scheme ?? "").lowercased() == "iexa" else { return }

        let host = (components.host ?? "").lowercased()
        if host == "chat" || host.isEmpty {
            let sessionValue = components.queryItems?.first(where: { $0.name == "session" })?.value
            viewModel.openSessionFromDeepLink(sessionValue)
        }
    }
}
