import SwiftUI

@main
struct ChatAppiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var authViewModel = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(authViewModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                viewModel.appDidEnterBackground()
            case .active:
                viewModel.appDidBecomeActive()
            case .inactive:
                viewModel.appWillResignActive()
            @unknown default:
                break
            }
        }
    }
}
