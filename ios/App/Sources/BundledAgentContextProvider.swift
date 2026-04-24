import Foundation

enum BundledAgentContextProvider {
    private static let memoryResource = "IEXA_AGENT_MEMORY"
    private static let planResource = "IEXA_AGENT_PLAN"
    private static let maxContextCharacters = 1_800
    private static let cachedMemoryContext = loadMarkdownResource(named: memoryResource)
    private static let cachedPlanContext = loadMarkdownResource(named: planResource)

    static func memoryContext() -> String? {
        cachedMemoryContext
    }

    static func planContext() -> String? {
        cachedPlanContext
    }

    private static func loadMarkdownResource(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else {
            return nil
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maxContextCharacters))
    }
}
