import SwiftUI
import UIKit
import WebKit

struct RemoteImageView: View {
    let urlString: String
    let apiKey: String
    let baseURL: String

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
            await loader.load(urlString: urlString, apiKey: apiKey, baseURL: baseURL)
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

    func load(urlString rawURL: String, apiKey rawAPIKey: String, baseURL: String) async {
        image = nil
        svgText = nil
        failed = false

        let normalizedURL = Self.normalizeURL(rawURL, baseURL: baseURL)
        guard let normalizedURL else {
            failed = true
            return
        }

        if normalizedURL.hasPrefix("data:"),
           let decoded = Self.decodeDataURL(normalizedURL) {
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

        guard let url = URL(string: normalizedURL) else {
            failed = true
            return
        }

        do {
            var plainRequest = URLRequest(url: url, timeoutInterval: 60)
            plainRequest.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            let (plainData, plainResponse) = try await URLSession.shared.data(for: plainRequest)
            if Self.isSuccessResponse(plainResponse) {
                if let resolved = Self.resolveDisplayContent(data: plainData, response: plainResponse) {
                    switch resolved {
                    case .raster(let uiImage):
                        image = uiImage
                    case .svg(let text):
                        svgText = text
                    }
                    return
                }
            }
        } catch {
            // Fall through to auth retry if API key exists.
        }

        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            failed = true
            return
        }

        do {
            var authRequest = URLRequest(url: url, timeoutInterval: 60)
            authRequest.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            authRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (authData, authResponse) = try await URLSession.shared.data(for: authRequest)
            if Self.isSuccessResponse(authResponse),
               let resolved = Self.resolveDisplayContent(data: authData, response: authResponse) {
                switch resolved {
                case .raster(let uiImage):
                    image = uiImage
                case .svg(let text):
                    svgText = text
                }
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }

    private static func isSuccessResponse(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
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
            return (mimeType: mimeType, data: data)
        }

        if let decoded = payload.removingPercentEncoding?.data(using: .utf8) {
            return (mimeType: mimeType, data: decoded)
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
            let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
