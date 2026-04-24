import SwiftUI
import WebKit
import UIKit

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
            VStack(spacing: 0) {
                previewHeader

                if let entryPathDisplay {
                    HStack(spacing: 10) {
                        Text("预览")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(MinisTheme.accentBlue)
                            )

                        Text(entryPathDisplay)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MinisTheme.secondaryText)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(MinisTheme.softPill)
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }

                HTMLPreviewWebView(html: html, baseURL: baseURL, entryFileURL: entryFileURL)
                    .ignoresSafeArea(edges: .bottom)
                    .padding(.top, entryPathDisplay == nil ? 0 : 10)
            }
            .background(MinisTheme.appBackground.ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 14) {
            circleToolbarButton(systemName: "xmark") {
                dismiss()
            }

            Spacer(minLength: 0)

            Text(titleForDisplay)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let targetURL = entryFileURL ?? baseURL {
                circleToolbarButton(systemName: "globe") {
                    UIApplication.shared.open(targetURL)
                }
            } else {
                Color.clear
                    .frame(width: 42, height: 42)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(MinisTheme.panelBackground)
    }

    private var titleForDisplay: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "IEXA 电脑" : trimmed
    }

    private var entryPathDisplay: String? {
        let path = entryFileURL?.path ?? baseURL?.absoluteString
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func circleToolbarButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(MinisTheme.softPill)
                )
        }
        .buttonStyle(.plain)
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
        let webViewIdentity = ObjectIdentifier(webView)
        let sameWebView = context.coordinator.lastWebViewIdentity == webViewIdentity

        if let entryFileURL {
            let readAccessURL = baseURL ?? entryFileURL.deletingLastPathComponent()
            let entryExt = entryFileURL.pathExtension.lowercased()
            let shouldUsePHPRuntime = entryExt == "php"
                || entryExt == "phtml"
                || PHPPreviewRuntimeBuilder.projectContainsPHPFiles(projectRootURL: readAccessURL)

            if shouldUsePHPRuntime,
               let runtime = PHPPreviewRuntimeBuilder.makeRuntimeDocument(
                   projectRootURL: readAccessURL,
                   entryFileURL: entryFileURL
               ) {
                if sameWebView,
                   context.coordinator.lastEntryFileURL == entryFileURL,
                   context.coordinator.lastBaseURL == readAccessURL,
                   context.coordinator.lastPHPRuntimeSignature == runtime.signature {
                    return
                }

                context.coordinator.lastLoadedHTML = html
                context.coordinator.lastBaseURL = readAccessURL
                context.coordinator.lastEntryFileURL = entryFileURL
                context.coordinator.lastWebViewIdentity = webViewIdentity
                context.coordinator.lastPHPRuntimeSignature = runtime.signature
                webView.loadHTMLString(runtime.html, baseURL: readAccessURL)
                return
            }

            if sameWebView,
               context.coordinator.lastEntryFileURL == entryFileURL,
               context.coordinator.lastBaseURL == baseURL,
               webView.url == entryFileURL {
                return
            }

            context.coordinator.lastLoadedHTML = html
            context.coordinator.lastBaseURL = baseURL
            context.coordinator.lastEntryFileURL = entryFileURL
            context.coordinator.lastWebViewIdentity = webViewIdentity
            context.coordinator.lastPHPRuntimeSignature = nil
            webView.loadFileURL(entryFileURL, allowingReadAccessTo: readAccessURL)
            return
        }

        if sameWebView,
            context.coordinator.lastLoadedHTML == html
            && context.coordinator.lastBaseURL == baseURL
            && context.coordinator.lastEntryFileURL == nil {
            return
        }
        context.coordinator.lastLoadedHTML = html
        context.coordinator.lastBaseURL = baseURL
        context.coordinator.lastEntryFileURL = nil
        context.coordinator.lastWebViewIdentity = webViewIdentity
        context.coordinator.lastPHPRuntimeSignature = nil
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastLoadedHTML: String = ""
        var lastBaseURL: URL?
        var lastEntryFileURL: URL?
        var lastWebViewIdentity: ObjectIdentifier?
        var lastPHPRuntimeSignature: String?
    }
}
