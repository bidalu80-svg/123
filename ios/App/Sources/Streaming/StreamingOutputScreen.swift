import SwiftUI

struct StreamingOutputControllerHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> StreamingOutputViewController {
        StreamingOutputViewController()
    }

    func updateUIViewController(_ uiViewController: StreamingOutputViewController, context: Context) {}
}

struct StreamingRenderLabScreen: View {
    var body: some View {
        StreamingOutputControllerHost()
            .ignoresSafeArea(edges: .bottom)
    }
}
