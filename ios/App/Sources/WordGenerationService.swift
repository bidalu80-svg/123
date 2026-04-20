import Foundation

struct WordGenerationResult: Equatable {
    let fileURL: URL
    let fileName: String
    let blockCount: Int
}

enum WordGenerationError: LocalizedError {
    case noContent
    case missingTemplateResource
    case invalidPayload
    case runtimeUnavailable(String)
    case generationFailed(String)
    case invalidGeneratorOutput
    case generatedFileMissing
    case outputDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "没有识别到可用于生成 Word 的内容。"
        case .missingTemplateResource:
            return "缺少内置 Word 模板文件（OfficeTemplates/template.docx）。"
        case .invalidPayload:
            return "无法构建 Word 生成参数。"
        case .runtimeUnavailable(let detail):
            return "本地 Word 生成依赖嵌入 CPython 运行时，当前不可用。\n\(detail)"
        case .generationFailed(let detail):
            return "Word 生成失败：\(detail)"
        case .invalidGeneratorOutput:
            return "Word 生成器返回了无法识别的结果。"
        case .generatedFileMissing:
            return "Word 生成完成，但未找到输出文件。"
        case .outputDirectoryUnavailable(let detail):
            return "无法创建本地 Word 目录：\(detail)"
        }
    }
}

final class WordGenerationService {
    enum BlockKind: String, Codable {
        case heading1
        case heading2
        case paragraph
        case bullet
    }

    struct Block: Equatable {
        let kind: BlockKind
        let text: String
    }

    private struct PythonBlockPayload: Codable {
        let kind: String
        let text: String
    }

    private struct PythonBuildPayload: Codable {
        let templatePath: String
        let outputPath: String
        let blocks: [PythonBlockPayload]
    }

    private struct PythonBuildAck {
        let outputPath: String
        let blockCount: Int
    }

    static let shared = WordGenerationService()

    private static let maxBlocks = 220
    private static let maxTextLength = 600

    private let fileManager = FileManager.default
    private let payloadEncoder = JSONEncoder()

    private init() {}

    static func canGenerate(from message: ChatMessage) -> Bool {
        let source = mergedSourceText(from: message)
        guard hasWordSignals(in: source) else { return false }

        let blocks = extractBlocks(from: message)
        guard !blocks.isEmpty else { return false }

        let hasStructured = blocks.contains { block in
            block.kind == .heading1 || block.kind == .heading2 || block.kind == .bullet
        }
        if hasStructured { return true }

        let totalLength = blocks.reduce(into: 0) { partial, block in
            partial += block.text.count
        }
        return blocks.count >= 3 || totalLength >= 120
    }

    func generate(from message: ChatMessage) async throws -> WordGenerationResult {
        let blocks = Self.extractBlocks(from: message)
        guard !blocks.isEmpty else {
            throw WordGenerationError.noContent
        }

        guard let templateURL = Self.resolveTemplateURL() else {
            throw WordGenerationError.missingTemplateResource
        }

        let outputURL = try makeOutputURL()
        let payload = PythonBuildPayload(
            templatePath: templateURL.path,
            outputPath: outputURL.path,
            blocks: blocks.map { block in
                PythonBlockPayload(kind: block.kind.rawValue, text: block.text)
            }
        )

        guard let stdin = encodePayload(payload) else {
            throw WordGenerationError.invalidPayload
        }

        let result = try await PythonExecutionService.shared.runPython(
            code: Self.pythonGeneratorScript,
            stdin: stdin,
            waitForEmbeddedRuntimeRecovery: true
        )

        guard result.exitCode == 0 else {
            throw mapRuntimeFailure(result.output)
        }

        guard let ack = parseBuildAck(result.output) else {
            throw WordGenerationError.invalidGeneratorOutput
        }

        let builtURL = URL(fileURLWithPath: ack.outputPath)
        guard fileManager.fileExists(atPath: builtURL.path) else {
            throw WordGenerationError.generatedFileMissing
        }

        return WordGenerationResult(
            fileURL: builtURL,
            fileName: builtURL.lastPathComponent,
            blockCount: max(blocks.count, ack.blockCount)
        )
    }

    static func extractBlocks(from message: ChatMessage) -> [Block] {
        extractBlocks(from: mergedSourceText(from: message))
    }

    static func extractBlocks(from rawText: String) -> [Block] {
        let text = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let withoutCodeFence = text.replacingOccurrences(
            of: #"(?s)```.*?```"#,
            with: "\n",
            options: .regularExpression
        )
        let lines = withoutCodeFence
            .components(separatedBy: "\n")
            .map(normalizeLine(_:))

        var blocks: [Block] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let text = clipped(
                paragraphBuffer.joined(separator: " "),
                limit: maxTextLength
            )
            if !text.isEmpty {
                blocks.append(Block(kind: .paragraph, text: text))
            }
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if isMetadataLine(line) { continue }

            if let heading = headingBlock(from: line) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if let bullet = bulletText(from: line) {
                flushParagraph()
                blocks.append(Block(kind: .bullet, text: clipped(bullet, limit: maxTextLength)))
                continue
            }

            paragraphBuffer.append(line)
        }
        flushParagraph()

        if blocks.isEmpty {
            let fallback = lines
                .filter { !$0.isEmpty && !isMetadataLine($0) }
                .prefix(6)
                .map { Block(kind: .paragraph, text: clipped($0, limit: maxTextLength)) }
            blocks = Array(fallback)
        }

        return Array(blocks.prefix(maxBlocks))
    }

    private func encodePayload(_ payload: PythonBuildPayload) -> String? {
        guard let data = try? payloadEncoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func mapRuntimeFailure(_ output: String) -> WordGenerationError {
        let detail = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lowered = detail.lowercased()

        if detail.contains("嵌入 CPython")
            || detail.contains("完整 CPython")
            || lowered.contains("runtime")
            || lowered.contains("import ") {
            return .runtimeUnavailable(detail)
        }

        return .generationFailed(detail.isEmpty ? "未知错误" : detail)
    }

    private func parseBuildAck(_ output: String) -> PythonBuildAck? {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.contains("IEXA_WORD_BUILD_OK") else { return nil }

        var outputPath: String?
        var blockCount: Int?
        for line in lines {
            if line.hasPrefix("output_path=") {
                outputPath = String(line.dropFirst("output_path=".count))
            } else if line.hasPrefix("blocks=") {
                blockCount = Int(String(line.dropFirst("blocks=".count)))
            }
        }

        guard let outputPath, !outputPath.isEmpty else { return nil }
        return PythonBuildAck(outputPath: outputPath, blockCount: max(1, blockCount ?? 1))
    }

    private func makeOutputURL() throws -> URL {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("iexa-word-output", isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw WordGenerationError.outputDirectoryUnavailable(error.localizedDescription)
        }

        cleanupOldFiles(in: folder)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(6)
        return folder.appendingPathComponent("document-\(stamp)-\(suffix).docx", isDirectory: false)
    }

    private func cleanupOldFiles(in directoryURL: URL) {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let expiryDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            if modifiedAt < expiryDate {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private static func mergedSourceText(from message: ChatMessage) -> String {
        var chunks: [String] = []
        let body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            chunks.append(body)
        }

        for file in message.fileAttachments {
            guard file.binaryBase64 == nil else { continue }
            let text = file.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let ext = (file.fileName as NSString).pathExtension.lowercased()
            let mime = file.mimeType.lowercased()
            if mime.hasPrefix("text/")
                || ["md", "txt", "markdown", "csv", "tsv", "json", "yaml", "yml"].contains(ext) {
                chunks.append(text)
            }
        }

        return chunks.joined(separator: "\n\n")
    }

    private static func normalizeLine(_ raw: String) -> String {
        var line = raw.replacingOccurrences(of: "\t", with: " ")
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "" }

        line = line.replacingOccurrences(of: #"(?<!\*)\*\*(.+?)\*\*(?!\*)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headingBlock(from line: String) -> Block? {
        if let h1 = firstMatch(in: line, pattern: #"^#\s+(.+)$"#) {
            return Block(kind: .heading1, text: clipped(h1, limit: maxTextLength))
        }
        if let h2 = firstMatch(in: line, pattern: #"^#{2,6}\s+(.+)$"#) {
            return Block(kind: .heading2, text: clipped(h2, limit: maxTextLength))
        }
        if let named = firstMatch(
            in: line,
            pattern: #"^(?:标题|主题|title)\s*[:：]\s*(.+)$"#,
            options: [.caseInsensitive]
        ) {
            return Block(kind: .heading1, text: clipped(named, limit: maxTextLength))
        }
        if (line.hasSuffix(":") || line.hasSuffix("：")) && line.count <= 42 {
            let raw = String(line.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            return Block(kind: .heading2, text: clipped(raw, limit: maxTextLength))
        }
        return nil
    }

    private static func bulletText(from line: String) -> String? {
        if let bullet = firstMatch(in: line, pattern: #"^[-*•·●▪◦]\s+(.+)$"#) {
            return bullet
        }
        if let numbered = firstMatch(in: line, pattern: #"^\d+[\.\)、]\s+(.+)$"#) {
            return numbered
        }
        if let alpha = firstMatch(in: line, pattern: #"^[A-Za-z][\.\)]\s+(.+)$"#) {
            return alpha
        }
        return nil
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("[[file:") || lowered == "[[endfile]]" {
            return true
        }
        if lowered == "[iexa_project_progress]" || lowered == "[iexa_frontend_progress]" {
            return true
        }
        if lowered.hasPrefix("state=") || lowered.hasPrefix("files=") || lowered.hasPrefix("entry=") {
            return true
        }
        return false
    }

    private static func firstMatch(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        let group = match.range(at: 1)
        guard group.location != NSNotFound else { return nil }
        return ns.substring(with: group).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func hasWordSignals(in rawText: String) -> Bool {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let lowered = text.lowercased()

        let keywords = [
            "word", "docx", "文档", "报告", "纪要", "说明书", "简历", "合同", "proposal"
        ]
        if keywords.contains(where: { lowered.contains($0) }) {
            return true
        }

        if text.range(of: #"(?m)^#{1,6}\s+\S+"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?m)^\s*[-*•·●▪◦]\s+\S+"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?m)^\s*\d+[\.\)、]\s+\S+"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func resolveTemplateURL() -> URL? {
        let bundle = Bundle.main
        if let inSubdir = bundle.url(
            forResource: "template",
            withExtension: "docx",
            subdirectory: "OfficeTemplates"
        ) {
            return inSubdir
        }
        if let inRoot = bundle.url(forResource: "template", withExtension: "docx") {
            return inRoot
        }

        if let resourceURL = bundle.resourceURL {
            let candidates = [
                resourceURL.appendingPathComponent("OfficeTemplates/template.docx"),
                resourceURL.appendingPathComponent("template.docx")
            ]
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static let pythonGeneratorScript = #"""
import json
import os
import zipfile
from io import BytesIO
from xml.etree import ElementTree as ET

W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
XML_NS = "http://www.w3.org/XML/1998/namespace"

ET.register_namespace("w", W_NS)


def w_tag(name):
    return f"{{{W_NS}}}{name}"


def build_paragraph(text, style=None):
    paragraph = ET.Element(w_tag("p"))
    if style:
        p_pr = ET.SubElement(paragraph, w_tag("pPr"))
        p_style = ET.SubElement(p_pr, w_tag("pStyle"))
        p_style.set(w_tag("val"), style)

    run = ET.SubElement(paragraph, w_tag("r"))
    text_node = ET.SubElement(run, w_tag("t"))
    if text.strip() != text:
        text_node.set(f"{{{XML_NS}}}space", "preserve")
    text_node.text = text
    return paragraph


def style_for_kind(kind):
    if kind == "heading1":
        return "Heading1"
    if kind == "heading2":
        return "Heading2"
    if kind == "bullet":
        return "ListBullet"
    return None


def main():
    payload = json.loads(sys.stdin.read() or "{}")
    template_path = (payload.get("templatePath") or "").strip()
    output_path = (payload.get("outputPath") or "").strip()
    blocks = payload.get("blocks") or []

    if not template_path:
        raise ValueError("template_path_missing")
    if not output_path:
        raise ValueError("output_path_missing")
    if not blocks:
        blocks = [{"kind": "paragraph", "text": "Generated by IEXA"}]

    with open(template_path, "rb") as f:
        template_data = f.read()
    with zipfile.ZipFile(BytesIO(template_data), "r") as zin:
        entries = {name: zin.read(name) for name in zin.namelist()}

    root = ET.fromstring(entries["word/document.xml"])
    body = root.find(f".//{{{W_NS}}}body")
    if body is None:
        raise ValueError("word_body_missing")

    sect_pr = None
    for child in list(body):
        if child.tag == w_tag("sectPr"):
            sect_pr = child
        body.remove(child)

    for block in blocks:
        text = str(block.get("text") or "").strip()
        if not text:
            continue
        style = style_for_kind(str(block.get("kind") or "paragraph"))
        body.append(build_paragraph(text, style=style))

    if sect_pr is not None:
        body.append(sect_pr)

    entries["word/document.xml"] = ET.tostring(root, encoding="utf-8", xml_declaration=True)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as zout:
        for name in sorted(entries.keys()):
            zout.writestr(name, entries[name])

    print("IEXA_WORD_BUILD_OK")
    print("blocks=" + str(len(blocks)))
    print("output_path=" + output_path)


if __name__ == "__main__":
    import sys
    main()
"""#
}
