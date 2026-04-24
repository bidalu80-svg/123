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

            WindowThemeBackgroundBridge()
                .allowsHitTesting(false)
        }
        .tint(.primary)
        .preferredColorScheme(viewModel.preferredColorScheme)
    }
}

private struct WindowThemeBackgroundBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> ResolverView {
        ResolverView()
    }

    func updateUIView(_ uiView: ResolverView, context: Context) {
        uiView.applyThemeBackground()
    }

    final class ResolverView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyThemeBackground()
        }

        func applyThemeBackground() {
            let color = MinisTheme.appBackgroundUIColor
            backgroundColor = .clear
            window?.backgroundColor = color
            window?.rootViewController?.view.backgroundColor = color
            superview?.backgroundColor = color
        }
    }
}
