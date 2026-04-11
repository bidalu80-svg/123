import SwiftUI

@main
struct ChatAppiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                viewModel.appDidEnterBackground()
            case .active:
                viewModel.appDidBecomeActive()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
