import Foundation

enum AppBuildInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static var appName: String {
        (info["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "IEXA"
    }

    static var marketingVersion: String {
        (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "?"
    }

    static var buildNumber: String {
        (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "?"
    }

    static var gitSHA: String {
        (info["IEXA_BUILD_GIT_SHA"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "unknown"
    }

    static var shortGitSHA: String {
        let trimmed = gitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        return String(trimmed.prefix(7))
    }

    static var runID: String {
        (info["IEXA_BUILD_RUN_ID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "unknown"
    }

    static var buildTimeRaw: String {
        (info["IEXA_BUILD_TIME"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "unknown"
    }

    static var buildTimeDisplay: String {
        let raw = buildTimeRaw
        guard raw != "unknown", raw != "local-build" else { return raw }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static var versionLine: String {
        "v\(marketingVersion) (\(buildNumber))"
    }

    static var buildSignature: String {
        "\(shortGitSHA) · run \(runID)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
