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

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if await loadContent(rawURL: rawURL, apiKey: trimmedKey, baseURL: baseURL, depth: 0, visited: Set<String>()) {
            return
        }
        failed = true
    }

    private func loadContent(
        rawURL: String,
        apiKey: String,
        baseURL: String,
        depth: Int,
        visited: Set<String>
    ) async -> Bool {
        guard depth <= 3 else { return false }
        guard let normalized = Self.normalizeURL(rawURL, baseURL: baseURL) else { return false }
        var seen = visited
        guard seen.insert(normalized).inserted else { return false }

        if normalized.hasPrefix("data:"),
           let decoded = Self.decodeDataURL(normalized) {
            if decoded.mimeType.contains("svg"),
               let text = String(data: decoded.data, encoding: .utf8),
               text.contains("<svg") {
                svgText = text
                return true
            }
            if let uiImage = UIImage(data: decoded.data) {
                image = uiImage
                return true
            }
        }

        guard let url = URL(string: normalized) else { return false }

        var attempts: [String?] = [nil]
        if !apiKey.isEmpty {
            attempts.append(apiKey)
        }

        for token in attempts {
            do {
                let (data, response) = try await fetch(url: url, apiKey: token)
                guard Self.isSuccessResponse(response) else { continue }

                if let resolved = Self.resolveDisplayContent(data: data, response: response) {
                    applyResolved(resolved)
                    return true
                }

                if let nextRaw = Self.extractNestedImageReference(data: data, response: response),
                   await loadContent(rawURL: nextRaw, apiKey: apiKey, baseURL: baseURL, depth: depth + 1, visited: seen) {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }

    private func fetch(url: URL, apiKey: String?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        request.setValue("Mozilla/5.0 ChatApp/1.0", forHTTPHeaderField: "User-Agent")
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

    private static func extractNestedImageReference(data: Data, response: URLResponse) -> String? {
        let mimeType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""

        if mimeType.contains("json"),
           let object = try? JSONSerialization.jsonObject(with: data),
           let candidate = scanImageReference(in: object) {
            return candidate
        }

        if let text = String(data: data, encoding: .utf8) {
            if let direct = MessageContentParser.extractInlineImageURLs(from: text).first {
                return direct
            }
            if let maybeURL = text
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>")) })
                .first(where: { value in
                    value.hasPrefix("http://")
                        || value.hasPrefix("https://")
                        || value.hasPrefix("/")
                        || value.hasPrefix("data:image")
                }) {
                return maybeURL
            }
        }

        return nil
    }

    private static func scanImageReference(in node: Any) -> String? {
        if let text = node as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data:image")
                || trimmed.hasPrefix("http://")
                || trimmed.hasPrefix("https://")
                || trimmed.hasPrefix("/") {
                return trimmed
            }
            return MessageContentParser.extractInlineImageURLs(from: trimmed).first
        }

        if let dict = node as? [String: Any] {
            if let imageURL = dict["image_url"] as? [String: Any] {
                if let b64 = imageURL["b64_json"] as? String, !b64.isEmpty {
                    return "data:image/png;base64,\(b64)"
                }
                if let url = imageURL["url"] as? String, !url.isEmpty {
                    return url
                }
            }

            if let imageURL = dict["image_url"] as? String, !imageURL.isEmpty {
                return imageURL
            }
            if let url = dict["url"] as? String, !url.isEmpty {
                return url
            }
            if let b64 = dict["b64_json"] as? String, !b64.isEmpty {
                return "data:image/png;base64,\(b64)"
            }

            for value in dict.values {
                if let candidate = scanImageReference(in: value) {
                    return candidate
                }
            }
        }

        if let array = node as? [Any] {
            for item in array {
                if let candidate = scanImageReference(in: item) {
                    return candidate
                }
            }
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
        cleaned = cleaned.replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "\\u003d", with: "=", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "\\u003f", with: "?", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "\\u002b", with: "+", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "\\u0025", with: "%", options: .caseInsensitive)

        if cleaned.hasPrefix("//") {
            cleaned = "https:\(cleaned)"
        }

        if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") || cleaned.hasPrefix("data:") {
            return cleaned
        }

        let normalizedBase = normalizeBaseURL(baseURL)
        guard let base = URL(string: normalizedBase) else { return nil }
        if let resolved = URL(string: cleaned, relativeTo: base)?.absoluteURL,
           let scheme = resolved.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return resolved.absoluteString
        }
        return nil
    }

    private static func normalizeBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
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
