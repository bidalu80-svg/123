import SwiftUI
import UIKit

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
    @Published var failed = false

    func load(urlString rawURL: String, apiKey rawAPIKey: String, baseURL: String) async {
        image = nil
        failed = false

        let normalizedURL = Self.normalizeURL(rawURL, baseURL: baseURL)
        guard let normalizedURL else {
            failed = true
            return
        }

        if normalizedURL.hasPrefix("data:image"),
           let data = Self.decodeDataURL(normalizedURL),
           let uiImage = UIImage(data: data) {
            image = uiImage
            return
        }

        guard let url = URL(string: normalizedURL) else {
            failed = true
            return
        }

        do {
            let plainRequest = URLRequest(url: url, timeoutInterval: 60)
            let (plainData, plainResponse) = try await URLSession.shared.data(for: plainRequest)
            if Self.isSuccessResponse(plainResponse), let uiImage = UIImage(data: plainData) {
                image = uiImage
                return
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
            authRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (authData, authResponse) = try await URLSession.shared.data(for: authRequest)
            if Self.isSuccessResponse(authResponse), let uiImage = UIImage(data: authData) {
                image = uiImage
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

    private static func decodeDataURL(_ dataURL: String) -> Data? {
        let parts = dataURL.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return Data(base64Encoded: parts[1])
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

        if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") || cleaned.hasPrefix("data:image") {
            return cleaned
        }
        return nil
    }
}
