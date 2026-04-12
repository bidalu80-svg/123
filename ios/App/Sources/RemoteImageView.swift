import SwiftUI
import UIKit
import WebKit

struct RemoteImageView: View {
    let urlString: String
    var apiKey: String = ""
    var baseURL: String = ""

    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let svgText = loader.svgText {
                SVGWebView(svgText: svgText)
                    .frame(minWidth: 120, minHeight: 120)
            } else if loader.failed {
                Text("图片加载失败")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: taskIdentity) {
            await loader.load(rawURL: urlString, apiKey: apiKey, baseURL: baseURL)
        }
    }

    private var taskIdentity: String {
        "\(urlString)|\(apiKey)|\(baseURL)"
    }
}

@MainActor
final class RemoteImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var svgText: String?
    @Published var failed = false

    func load(rawURL: String, apiKey: String, baseURL: String) async {
        image = nil
        svgText = nil
        failed = false

        guard let normalized = Self.normalizeURL(rawURL, baseURL: baseURL) else {
            failed = true
            return
        }

        if normalized.hasPrefix("data:"),
           let decoded = Self.decodeDataURL(normalized) {
            if decoded.mimeType.contains("svg"),
               let text = String(data: decoded.data, encoding: .utf8),
               text.contains("<svg") {
                svgText = text
                return
            }
            if let uiImage = UIImage(data: decoded.data) {
                image = uiImage
                return
            }
        }

        guard let url = URL(string: normalized) else {
            failed = true
            return
        }

        do {
            let (plainData, plainResponse) = try await fetch(url: url, apiKey: nil)
            if Self.isSuccessResponse(plainResponse),
               let resolved = Self.resolveDisplayContent(data: plainData, response: plainResponse) {
                applyResolved(resolved)
                return
            }
        } catch {
            // fall through to auth retry
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            failed = true
            return
        }

        do {
            let (authData, authResponse) = try await fetch(url: url, apiKey: trimmedKey)
            if Self.isSuccessResponse(authResponse),
               let resolved = Self.resolveDisplayContent(data: authData, response: authResponse) {
                applyResolved(resolved)
                return
            }
            failed = true
        } catch {
            failed = true
        }
    }

    private func fetch(url: URL, apiKey: String?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return try await URLSession.shared.data(for: request)
    }

    private func applyResolved(_ content: DisplayContent) {
        switch content {
        case .raster(let uiImage):
            image = uiImage
        case .svg(let text):
            svgText = text
        }
    }

    private enum DisplayContent {
        case raster(UIImage)
        case svg(String)
    }

    private static func resolveDisplayContent(data: Data, response: URLResponse) -> DisplayContent? {
        let mimeType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""

        if mimeType.contains("svg"),
           let text = String(data: data, encoding: .utf8),
           text.contains("<svg") {
            return .svg(text)
        }
        if let uiImage = UIImage(data: data) {
            return .raster(uiImage)
        }
        if let text = String(data: data, encoding: .utf8),
           text.contains("<svg") {
            return .svg(text)
        }
        return nil
    }

    private static func isSuccessResponse(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    private static func decodeDataURL(_ dataURL: String) -> (mimeType: String, data: Data)? {
        let parts = dataURL.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let header = parts[0].lowercased()
        let payload = parts[1]
        let mimeType = header
            .replacingOccurrences(of: "data:", with: "")
            .components(separatedBy: ";")
            .first ?? "application/octet-stream"

        if header.contains(";base64"), let data = Data(base64Encoded: payload) {
            return (mimeType, data)
        }
        if let decoded = payload.removingPercentEncoding?.data(using: .utf8) {
            return (mimeType, decoded)
        }
        return nil
    }

    private static func normalizeURL(_ raw: String, baseURL: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        cleaned = cleaned.replacingOccurrences(of: "\\/", with: "/")
        cleaned = cleaned.replacingOccurrences(of: "&amp;", with: "&")

        if cleaned.hasPrefix("//") {
            cleaned = "https:\(cleaned)"
        }

        if cleaned.hasPrefix("/") {
            let base = baseURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !base.isEmpty {
                cleaned = "\(base)\(cleaned)"
            }
        }

        if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") || cleaned.hasPrefix("data:") {
            return cleaned
        }
        return nil
    }
}

private struct SVGWebView: UIViewRepresentable {
    let svgText: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
        <body style="margin:0;padding:0;display:flex;justify-content:center;align-items:center;background:transparent;">
        \(svgText)
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
