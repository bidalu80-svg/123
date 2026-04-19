import SwiftUI
import WebKit

struct HTMLPreviewSheet: View {
    let title: String
    let html: String
    let baseURL: URL?
    let entryFileURL: URL?

    @Environment(\.dismiss) private var dismiss

    init(title: String, html: String, baseURL: URL? = nil, entryFileURL: URL? = nil) {
        self.title = title
        self.html = html
        self.baseURL = baseURL
        self.entryFileURL = entryFileURL
    }

    var body: some View {
        NavigationStack {
            HTMLPreviewWebView(html: html, baseURL: baseURL, entryFileURL: entryFileURL)
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
    let baseURL: URL?
    let entryFileURL: URL?

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
        if let entryFileURL {
            if context.coordinator.lastEntryFileURL == entryFileURL,
               context.coordinator.lastBaseURL == baseURL {
                return
            }

            context.coordinator.lastLoadedHTML = html
            context.coordinator.lastBaseURL = baseURL
            context.coordinator.lastEntryFileURL = entryFileURL
            let readAccessURL = baseURL ?? entryFileURL.deletingLastPathComponent()
            webView.loadFileURL(entryFileURL, allowingReadAccessTo: readAccessURL)
            return
        }

        if context.coordinator.lastLoadedHTML == html
            && context.coordinator.lastBaseURL == baseURL
            && context.coordinator.lastEntryFileURL == nil {
            return
        }
        context.coordinator.lastLoadedHTML = html
        context.coordinator.lastBaseURL = baseURL
        context.coordinator.lastEntryFileURL = nil
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastLoadedHTML: String = ""
        var lastBaseURL: URL?
        var lastEntryFileURL: URL?
    }
}
