import Foundation

struct PPTGenerationResult: Equatable {
    let fileURL: URL
    let fileName: String
    let slideCount: Int
}

enum PPTGenerationError: LocalizedError {
    case noOutlineContent
    case missingTemplateResource
    case invalidPayload
    case runtimeUnavailable(String)
    case generationFailed(String)
    case invalidGeneratorOutput
    case generatedFileMissing
    case outputDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noOutlineContent:
            return "没有识别到可用于生成 PPT 的大纲内容。"
        case .missingTemplateResource:
            return "缺少内置 PPT 模板文件（PPTTemplate/template.pptx）。"
        case .invalidPayload:
            return "无法构建 PPT 生成参数。"
        case .runtimeUnavailable(let detail):
            return "本地 PPT 生成依赖嵌入 CPython 运行时，当前不可用。\n\(detail)"
        case .generationFailed(let detail):
            return "PPT 生成失败：\(detail)"
        case .invalidGeneratorOutput:
            return "PPT 生成器返回了无法识别的结果。"
        case .generatedFileMissing:
            return "PPT 生成完成，但未找到输出文件。"
        case .outputDirectoryUnavailable(let detail):
            return "无法创建本地 PPT 目录：\(detail)"
        }
    }
}

final class PPTGenerationService {
    struct Outline: Equatable {
        struct Slide: Equatable {
            let title: String
            let bullets: [String]
        }

        let title: String
        let slides: [Slide]
    }

    private struct PythonSlidePayload: Codable {
        let title: String
        let bullets: [String]
    }

    private struct PythonBuildPayload: Codable {
        let deckTitle: String
        let templatePath: String
        let outputPath: String
        let slides: [PythonSlidePayload]
    }

    private struct PythonBuildAck {
        let outputPath: String
        let slideCount: Int
    }

    static let shared = PPTGenerationService()

    private static let maxSlides = 24
    private static let maxBulletsPerSlide = 8
    private static let maxTitleLength = 60
    private static let maxBulletLength = 120

    private let fileManager = FileManager.default
    private let payloadEncoder = JSONEncoder()

    private init() {}

    static func canGenerate(from message: ChatMessage) -> Bool {
        guard let outline = extractOutline(from: message) else { return false }
        let source = mergedOutlineText(from: message)
        return hasOutlineSignals(in: source)
            || outline.slides.count >= 2
            || (outline.slides.first?.bullets.count ?? 0) >= 2
    }

    func generate(from message: ChatMessage) async throws -> PPTGenerationResult {
        guard let outline = Self.extractOutline(from: message) else {
            throw PPTGenerationError.noOutlineContent
        }

        guard let templateURL = Bundle.main.url(
            forResource: "template",
            withExtension: "pptx",
            subdirectory: "PPTTemplate"
        ) else {
            throw PPTGenerationError.missingTemplateResource
        }

        let outputURL = try makeOutputURL(deckTitle: outline.title)
        let payload = PythonBuildPayload(
            deckTitle: outline.title,
            templatePath: templateURL.path,
            outputPath: outputURL.path,
            slides: outline.slides.map {
                PythonSlidePayload(title: $0.title, bullets: $0.bullets)
            }
        )

        guard let stdin = encodePayload(payload) else {
            throw PPTGenerationError.invalidPayload
        }

        let result = try await PythonExecutionService.shared.runPython(
            code: Self.pythonGeneratorScript,
            stdin: stdin
        )

        guard result.exitCode == 0 else {
            throw mapRuntimeFailure(result.output)
        }

        guard let ack = parseBuildAck(result.output) else {
            throw PPTGenerationError.invalidGeneratorOutput
        }

        let builtURL = URL(fileURLWithPath: ack.outputPath)
        guard fileManager.fileExists(atPath: builtURL.path) else {
            throw PPTGenerationError.generatedFileMissing
        }

        return PPTGenerationResult(
            fileURL: builtURL,
            fileName: builtURL.lastPathComponent,
            slideCount: max(ack.slideCount, outline.slides.count)
        )
    }

    static func extractOutline(from message: ChatMessage) -> Outline? {
        let merged = mergedOutlineText(from: message)
        return extractOutline(from: merged)
    }

    static func extractOutline(from rawText: String) -> Outline? {
        let text = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let withoutCodeFence = text.replacingOccurrences(
            of: #"(?s)```.*?```"#,
            with: "\n",
            options: .regularExpression
        )
        let lines = withoutCodeFence
            .components(separatedBy: "\n")
            .map(normalizeLine(_:))

        var slides: [Outline.Slide] = []
        var currentTitle: String?
        var currentBullets: [String] = []

        func flushCurrent() {
            let title = clipped(
                (currentTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                limit: maxTitleLength
            )
            let bullets = currentBullets
                .map { clipped($0, limit: maxBulletLength) }
                .filter { !$0.isEmpty }
                .prefix(maxBulletsPerSlide)
            if !title.isEmpty || !bullets.isEmpty {
                let fallbackTitle = title.isEmpty ? "第 \(slides.count + 1) 页" : title
                slides.append(
                    Outline.Slide(
                        title: fallbackTitle,
                        bullets: Array(bullets)
                    )
                )
            }
            currentTitle = nil
            currentBullets = []
        }

        for line in lines {
            guard !line.isEmpty else { continue }
            if isMetadataLine(line) { continue }

            if let slideTitle = slideHeader(from: line) {
                flushCurrent()
                currentTitle = slideTitle
                continue
            }

            if let bullet = bulletItem(from: line) {
                if currentTitle == nil {
                    currentTitle = "要点 \(slides.count + 1)"
                }
                currentBullets.append(bullet)
                continue
            }

            if currentTitle == nil {
                currentTitle = line
            } else {
                currentBullets.append(line)
            }
        }
        flushCurrent()

        if slides.isEmpty {
            slides = fallbackSlides(from: lines)
        }

        guard !slides.isEmpty else { return nil }

        let limitedSlides = Array(slides.prefix(maxSlides)).map { slide in
            Outline.Slide(
                title: clipped(slide.title, limit: maxTitleLength),
                bullets: Array(slide.bullets.prefix(maxBulletsPerSlide)).map {
                    clipped($0, limit: maxBulletLength)
                }
            )
        }

        let title = resolveDeckTitle(lines: lines, slides: limitedSlides)
        return Outline(title: title, slides: limitedSlides)
    }

    private func encodePayload(_ payload: PythonBuildPayload) -> String? {
        guard let data = try? payloadEncoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func mapRuntimeFailure(_ output: String) -> PPTGenerationError {
        let detail = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lowered = detail.lowercased()

        if detail.contains("嵌入 CPython")
            || detail.contains("完整 CPython")
            || lowered.contains("import ")
            || lowered.contains("runtime") {
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

        guard lines.contains("IEXA_PPT_BUILD_OK") else { return nil }

        var outputPath: String?
        var slideCount: Int?
        for line in lines {
            if line.hasPrefix("output_path=") {
                outputPath = String(line.dropFirst("output_path=".count))
            } else if line.hasPrefix("slides=") {
                slideCount = Int(String(line.dropFirst("slides=".count)))
            }
        }

        guard let outputPath, !outputPath.isEmpty else { return nil }
        return PythonBuildAck(outputPath: outputPath, slideCount: max(1, slideCount ?? 1))
    }

    private func makeOutputURL(deckTitle: String) throws -> URL {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("iexa-ppt-output", isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw PPTGenerationError.outputDirectoryUnavailable(error.localizedDescription)
        }

        cleanupOldFiles(in: folder)

        let stem = sanitizeFileName(deckTitle)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(6)
        let fileName = "\(stem)-\(stamp)-\(suffix).pptx"
        return folder.appendingPathComponent(fileName, isDirectory: false)
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

    private func sanitizeFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "presentation" }

        let illegal = CharacterSet(charactersIn: #"\/:*?"<>|"#)
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = trimmed.unicodeScalars.map { scalar -> Character in
            illegal.contains(scalar) ? "-" : Character(scalar)
        }
        let joined = String(cleaned)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return joined.isEmpty ? "presentation" : String(joined.prefix(48))
    }

    private static func mergedOutlineText(from message: ChatMessage) -> String {
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

    private static func resolveDeckTitle(lines: [String], slides: [Outline.Slide]) -> String {
        for line in lines {
            if let h1 = firstMatch(in: line, pattern: #"^#\s+(.+)$"#) {
                return clipped(h1, limit: maxTitleLength)
            }
        }

        for line in lines {
            if let named = firstMatch(
                in: line,
                pattern: #"^(?:标题|主题|title)\s*[:：]\s*(.+)$"#,
                options: [.caseInsensitive]
            ) {
                return clipped(named, limit: maxTitleLength)
            }
        }

        let genericTitleTokens = ["ppt", "presentation", "大纲", "outline", "演示文稿"]
        if let first = slides.first?.title {
            let lowered = first.lowercased()
            if !genericTitleTokens.contains(where: { lowered == $0 || lowered.contains($0) }) {
                return clipped(first, limit: maxTitleLength)
            }
        }

        for line in lines {
            if line.isEmpty || isMetadataLine(line) { continue }
            if bulletItem(from: line) != nil { continue }
            return clipped(line, limit: maxTitleLength)
        }
        return "演示文稿"
    }

    private static func fallbackSlides(from lines: [String]) -> [Outline.Slide] {
        let filtered = lines
            .filter { !$0.isEmpty && !isMetadataLine($0) }
            .map { clipped($0, limit: maxBulletLength) }
        guard !filtered.isEmpty else { return [] }

        if filtered.count <= 6 {
            let title = clipped(filtered[0], limit: maxTitleLength)
            let bullets = Array(filtered.dropFirst().prefix(maxBulletsPerSlide))
            return [Outline.Slide(title: title, bullets: bullets)]
        }

        let firstTitle = clipped(filtered[0], limit: maxTitleLength)
        var slides: [Outline.Slide] = [Outline.Slide(title: firstTitle, bullets: [])]

        let chunkSize = 5
        var index = 1
        var page = 1
        while index < filtered.count && slides.count < maxSlides {
            let upper = min(filtered.count, index + chunkSize)
            let chunk = Array(filtered[index..<upper])
            slides.append(
                Outline.Slide(
                    title: "要点 \(page)",
                    bullets: chunk
                )
            )
            index = upper
            page += 1
        }
        return slides
    }

    private static func slideHeader(from line: String) -> String? {
        if let markdown = firstMatch(in: line, pattern: #"^#{1,6}\s+(.+)$"#) {
            return clipped(markdown, limit: maxTitleLength)
        }

        if let keyword = firstMatch(
            in: line,
            pattern: #"^(?:slide|幻灯片|第\s*\d+\s*页|章节|section)\s*[:：\-]?\s*(.+)$"#,
            options: [.caseInsensitive]
        ) {
            return clipped(keyword, limit: maxTitleLength)
        }

        if let numbered = firstMatch(in: line, pattern: #"^\d+[\.\)、]\s*(.+)$"#),
           numbered.count <= 36 {
            return clipped(numbered, limit: maxTitleLength)
        }

        if (line.hasSuffix(":") || line.hasSuffix("：")) && line.count <= 44 {
            let raw = String(line.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                return clipped(raw, limit: maxTitleLength)
            }
        }
        return nil
    }

    private static func bulletItem(from line: String) -> String? {
        if let bullet = firstMatch(in: line, pattern: #"^[-*•·●▪◦]\s+(.+)$"#) {
            return clipped(bullet, limit: maxBulletLength)
        }
        if let alpha = firstMatch(in: line, pattern: #"^[A-Za-z][\.\)]\s+(.+)$"#) {
            return clipped(alpha, limit: maxBulletLength)
        }
        if let numbered = firstMatch(in: line, pattern: #"^\d+[\.\)、]\s+(.+)$"#),
           numbered.count > 36 {
            return clipped(numbered, limit: maxBulletLength)
        }
        return nil
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

    private static func hasOutlineSignals(in rawText: String) -> Bool {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let lowered = text.lowercased()

        let keywordSignals = [
            "ppt", "slide", "deck", "大纲", "演示", "汇报", "路演", "方案", "提案", "开题"
        ]
        if keywordSignals.contains(where: { lowered.contains($0) }) {
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

    private static let pythonGeneratorScript = #"""
import json
import os
import re
import zipfile
from io import BytesIO
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape

CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
P_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"
R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
A_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"

ET.register_namespace("", CT_NS)
ET.register_namespace("", REL_NS)
ET.register_namespace("p", P_NS)
ET.register_namespace("a", A_NS)
ET.register_namespace("r", R_NS)


def parse_rid(raw):
    matched = re.match(r"rId(\d+)$", raw or "")
    return int(matched.group(1)) if matched else 0


def paragraphs_xml(lines):
    chunks = ["<a:bodyPr/><a:lstStyle/>"]
    for line in lines:
        text = (line or "").strip()
        if not text:
            continue
        chunks.append(f"<a:p><a:r><a:t>{escape(text)}</a:t></a:r></a:p>")
    if len(chunks) == 1:
        return '<a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p>'
    return "".join(chunks)


def build_slide_xml(title, bullets):
    title_text = (title or "Untitled").strip() or "Untitled"
    bullet_lines = [f"• {(item or '').strip()}" for item in bullets if (item or "").strip()]
    body_xml = paragraphs_xml(bullet_lines)
    title_xml = paragraphs_xml([title_text])
    return f"""<?xml version='1.0' encoding='UTF-8' standalone='yes'?>
<p:sld xmlns:a='{A_NS}' xmlns:p='{P_NS}' xmlns:r='{R_NS}'>
  <p:cSld>
    <p:spTree>
      <p:nvGrpSpPr>
        <p:cNvPr id='1' name=''/>
        <p:cNvGrpSpPr/>
        <p:nvPr/>
      </p:nvGrpSpPr>
      <p:grpSpPr/>
      <p:sp>
        <p:nvSpPr>
          <p:cNvPr id='2' name='Title 1'/>
          <p:cNvSpPr><a:spLocks noGrp='1'/></p:cNvSpPr>
          <p:nvPr><p:ph type='title'/></p:nvPr>
        </p:nvSpPr>
        <p:spPr/>
        <p:txBody>{title_xml}</p:txBody>
      </p:sp>
      <p:sp>
        <p:nvSpPr>
          <p:cNvPr id='3' name='Content Placeholder 2'/>
          <p:cNvSpPr><a:spLocks noGrp='1'/></p:cNvSpPr>
          <p:nvPr><p:ph idx='1'/></p:nvPr>
        </p:nvSpPr>
        <p:spPr/>
        <p:txBody>{body_xml}</p:txBody>
      </p:sp>
    </p:spTree>
  </p:cSld>
  <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>
""".encode("utf-8")


def build_slide_rel_xml():
    return f"""<?xml version='1.0' encoding='UTF-8' standalone='yes'?>
<Relationships xmlns='{REL_NS}'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout' Target='../slideLayouts/slideLayout2.xml'/></Relationships>
""".encode("utf-8")


def update_content_types(entries, slide_count):
    root = ET.fromstring(entries["[Content_Types].xml"])
    for node in list(root):
        if node.tag == f"{{{CT_NS}}}Override" and node.attrib.get("PartName", "").startswith("/ppt/slides/slide"):
            root.remove(node)
    for index in range(1, slide_count + 1):
        override = ET.Element(f"{{{CT_NS}}}Override")
        override.set("PartName", f"/ppt/slides/slide{index}.xml")
        override.set("ContentType", "application/vnd.openxmlformats-officedocument.presentationml.slide+xml")
        root.append(override)
    entries["[Content_Types].xml"] = ET.tostring(root, encoding="utf-8", xml_declaration=True)


def update_presentation_relationships(entries, slide_count):
    root = ET.fromstring(entries["ppt/_rels/presentation.xml.rels"])
    for relation in list(root):
        if relation.attrib.get("Type", "").endswith("/slide"):
            root.remove(relation)

    max_existing = 0
    for relation in root:
        max_existing = max(max_existing, parse_rid(relation.attrib.get("Id", "")))

    relation_ids = []
    for offset in range(slide_count):
        rid = f"rId{max_existing + offset + 1}"
        relation = ET.Element(f"{{{REL_NS}}}Relationship")
        relation.set("Id", rid)
        relation.set("Type", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide")
        relation.set("Target", f"slides/slide{offset + 1}.xml")
        root.append(relation)
        relation_ids.append(rid)

    entries["ppt/_rels/presentation.xml.rels"] = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    return relation_ids


def update_presentation(entries, relation_ids):
    root = ET.fromstring(entries["ppt/presentation.xml"])
    sld_id_list = root.find(f"{{{P_NS}}}sldIdLst")
    if sld_id_list is None:
        sld_id_list = ET.SubElement(root, f"{{{P_NS}}}sldIdLst")
    else:
        for child in list(sld_id_list):
            sld_id_list.remove(child)

    for offset, relation_id in enumerate(relation_ids):
        sld_id = ET.SubElement(sld_id_list, f"{{{P_NS}}}sldId")
        sld_id.set("id", str(256 + offset))
        sld_id.set(f"{{{R_NS}}}id", relation_id)

    entries["ppt/presentation.xml"] = ET.tostring(root, encoding="utf-8", xml_declaration=True)


def rebuild_slide_parts(entries, slides):
    for name in list(entries.keys()):
        if name.startswith("ppt/slides/slide") or name.startswith("ppt/slides/_rels/slide"):
            entries.pop(name, None)

    for idx, slide in enumerate(slides, start=1):
        entries[f"ppt/slides/slide{idx}.xml"] = build_slide_xml(
            slide.get("title"),
            slide.get("bullets") or []
        )
        entries[f"ppt/slides/_rels/slide{idx}.xml.rels"] = build_slide_rel_xml()


def main():
    payload = json.loads(sys.stdin.read() or "{}")
    template_path = (payload.get("templatePath") or "").strip()
    output_path = (payload.get("outputPath") or "").strip()
    slides = payload.get("slides") or []

    if not template_path:
        raise ValueError("template_path_missing")
    if not output_path:
        raise ValueError("output_path_missing")

    if not slides:
        slides = [{"title": payload.get("deckTitle") or "演示文稿", "bullets": []}]

    with open(template_path, "rb") as f:
        template_data = f.read()

    with zipfile.ZipFile(BytesIO(template_data), "r") as zin:
        entries = {name: zin.read(name) for name in zin.namelist()}

    slide_count = max(1, len(slides))
    update_content_types(entries, slide_count)
    relation_ids = update_presentation_relationships(entries, slide_count)
    update_presentation(entries, relation_ids)
    rebuild_slide_parts(entries, slides)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as zout:
        for name in sorted(entries.keys()):
            zout.writestr(name, entries[name])

    print("IEXA_PPT_BUILD_OK")
    print("slides=" + str(slide_count))
    print("output_path=" + output_path)


if __name__ == "__main__":
    import sys
    main()
"""#
}
