import SwiftUI
import WebKit

struct HTMLPreviewSheet: View {
    let title: String
    let html: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HTMLPreviewWebView(html: html)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(titleForDisplay)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            dismiss()
                        }
                    }
                }
        }
    }

    private var titleForDisplay: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "网页预览" : trimmed
    }
}

private struct HTMLPreviewWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        webView.scrollView.keyboardDismissMode = .onDrag
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedHTML == html {
            return
        }
        context.coordinator.lastLoadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastLoadedHTML: String = ""
    }
}
