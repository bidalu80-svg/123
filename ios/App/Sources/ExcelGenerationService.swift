import Foundation

struct ExcelGenerationResult: Equatable {
    let fileURL: URL
    let fileName: String
    let sheetCount: Int
    let rowCount: Int
}

enum ExcelGenerationError: LocalizedError {
    case noTabularContent
    case missingTemplateResource
    case invalidPayload
    case runtimeUnavailable(String)
    case generationFailed(String)
    case invalidGeneratorOutput
    case generatedFileMissing
    case outputDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noTabularContent:
            return "没有识别到可用于生成 Excel 的表格内容。"
        case .missingTemplateResource:
            return "缺少内置 Excel 模板文件（OfficeTemplates/template.xlsx）。"
        case .invalidPayload:
            return "无法构建 Excel 生成参数。"
        case .runtimeUnavailable(let detail):
            return "本地 Excel 生成依赖嵌入 CPython 运行时，当前不可用。\n\(detail)"
        case .generationFailed(let detail):
            return "Excel 生成失败：\(detail)"
        case .invalidGeneratorOutput:
            return "Excel 生成器返回了无法识别的结果。"
        case .generatedFileMissing:
            return "Excel 生成完成，但未找到输出文件。"
        case .outputDirectoryUnavailable(let detail):
            return "无法创建本地 Excel 目录：\(detail)"
        }
    }
}

final class ExcelGenerationService {
    struct Sheet: Equatable {
        let name: String
        let headers: [String]
        let rows: [[String]]
    }

    private struct PythonSheetPayload: Codable {
        let name: String
        let rows: [[String]]
    }

    private struct PythonBuildPayload: Codable {
        let templatePath: String
        let outputPath: String
        let sheets: [PythonSheetPayload]
    }

    private struct PythonBuildAck {
        let outputPath: String
        let sheetCount: Int
        let rowCount: Int
    }

    static let shared = ExcelGenerationService()

    private static let maxSheets = 10
    private static let maxRowsPerSheet = 500
    private static let maxColumnsPerSheet = 24
    private static let maxCellLength = 240

    private let fileManager = FileManager.default
    private let payloadEncoder = JSONEncoder()

    private init() {}

    static func canGenerate(from message: ChatMessage) -> Bool {
        !extractSheets(from: message).isEmpty
    }

    func generate(from message: ChatMessage) async throws -> ExcelGenerationResult {
        let sheets = Self.extractSheets(from: message)
        guard !sheets.isEmpty else {
            throw ExcelGenerationError.noTabularContent
        }

        guard let templateURL = Bundle.main.url(
            forResource: "template",
            withExtension: "xlsx",
            subdirectory: "OfficeTemplates"
        ) else {
            throw ExcelGenerationError.missingTemplateResource
        }

        let outputURL = try makeOutputURL()
        let pythonSheets = sheets.map { sheet in
            PythonSheetPayload(
                name: sheet.name,
                rows: [sheet.headers] + sheet.rows
            )
        }
        let payload = PythonBuildPayload(
            templatePath: templateURL.path,
            outputPath: outputURL.path,
            sheets: pythonSheets
        )

        guard let stdin = encodePayload(payload) else {
            throw ExcelGenerationError.invalidPayload
        }

        let result = try await PythonExecutionService.shared.runPython(
            code: Self.pythonGeneratorScript,
            stdin: stdin
        )

        guard result.exitCode == 0 else {
            throw mapRuntimeFailure(result.output)
        }

        guard let ack = parseBuildAck(result.output) else {
            throw ExcelGenerationError.invalidGeneratorOutput
        }

        let builtURL = URL(fileURLWithPath: ack.outputPath)
        guard fileManager.fileExists(atPath: builtURL.path) else {
            throw ExcelGenerationError.generatedFileMissing
        }

        let rowCount = sheets.reduce(into: 0) { partial, sheet in
            partial += sheet.rows.count
        }
        return ExcelGenerationResult(
            fileURL: builtURL,
            fileName: builtURL.lastPathComponent,
            sheetCount: max(ack.sheetCount, sheets.count),
            rowCount: max(ack.rowCount, rowCount)
        )
    }

    static func extractSheets(from message: ChatMessage) -> [Sheet] {
        var collected: [Sheet] = []

        let segments = MessageContentParser.parse(message)
        for segment in segments {
            guard case let .table(headers, rows) = segment else { continue }
            if let normalized = normalizeSheet(
                preferredName: "表\(collected.count + 1)",
                headers: headers,
                rows: rows
            ) {
                collected.append(normalized)
            }
        }

        for file in message.fileAttachments {
            guard file.binaryBase64 == nil else { continue }
            let ext = (file.fileName as NSString).pathExtension.lowercased()
            guard ext == "csv" || ext == "tsv" else { continue }
            let delimiter: Character = (ext == "tsv") ? "\t" : ","
            let parsed = parseDelimitedTable(file.textContent, delimiter: delimiter)
            if let normalized = normalizeSheet(
                preferredName: (file.fileName as NSString).deletingPathExtension,
                headers: parsed.headers,
                rows: parsed.rows
            ) {
                collected.append(normalized)
            }
        }

        let deduped = deduplicateSheets(collected)
        let uniqued = ensureUniqueSheetNames(deduped)
        return Array(uniqued.prefix(maxSheets))
    }

    private func encodePayload(_ payload: PythonBuildPayload) -> String? {
        guard let data = try? payloadEncoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func mapRuntimeFailure(_ output: String) -> ExcelGenerationError {
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

        guard lines.contains("IEXA_EXCEL_BUILD_OK") else { return nil }

        var outputPath: String?
        var sheetCount: Int?
        var rowCount: Int?
        for line in lines {
            if line.hasPrefix("output_path=") {
                outputPath = String(line.dropFirst("output_path=".count))
            } else if line.hasPrefix("sheets=") {
                sheetCount = Int(String(line.dropFirst("sheets=".count)))
            } else if line.hasPrefix("rows=") {
                rowCount = Int(String(line.dropFirst("rows=".count)))
            }
        }

        guard let outputPath, !outputPath.isEmpty else { return nil }
        return PythonBuildAck(
            outputPath: outputPath,
            sheetCount: max(1, sheetCount ?? 1),
            rowCount: max(0, rowCount ?? 0)
        )
    }

    private func makeOutputURL() throws -> URL {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("iexa-excel-output", isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExcelGenerationError.outputDirectoryUnavailable(error.localizedDescription)
        }

        cleanupOldFiles(in: folder)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(6)
        return folder.appendingPathComponent("table-\(stamp)-\(suffix).xlsx", isDirectory: false)
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

    private static func normalizeSheet(
        preferredName: String,
        headers rawHeaders: [String],
        rows rawRows: [[String]]
    ) -> Sheet? {
        let trimmedHeaders = rawHeaders.map { clippedCell($0) }
        let trimmedRows = rawRows.map { row in row.map(clippedCell(_:)) }
        let maxColumns = max(
            trimmedHeaders.count,
            trimmedRows.map(\.count).max() ?? 0
        )
        guard maxColumns >= 2 else { return nil }

        let columnCount = min(maxColumns, maxColumnsPerSheet)
        var headers: [String]
        if trimmedHeaders.isEmpty {
            headers = (0..<columnCount).map { "列\($0 + 1)" }
        } else {
            headers = normalizeRow(trimmedHeaders, targetCount: columnCount)
        }
        headers = headers.enumerated().map { index, value in
            let fallback = "列\(index + 1)"
            return value.isEmpty ? fallback : value
        }

        let rows = trimmedRows
            .map { normalizeRow($0, targetCount: columnCount) }
            .filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        let limitedRows = Array(rows.prefix(maxRowsPerSheet))

        if limitedRows.isEmpty && headers.allSatisfy({ $0.isEmpty }) {
            return nil
        }

        return Sheet(
            name: sanitizeSheetName(preferredName),
            headers: headers,
            rows: limitedRows
        )
    }

    private static func normalizeRow(_ row: [String], targetCount: Int) -> [String] {
        guard targetCount > 0 else { return [] }
        if row.count == targetCount { return row }
        if row.count > targetCount {
            return Array(row.prefix(targetCount))
        }
        return row + Array(repeating: "", count: targetCount - row.count)
    }

    private static func parseDelimitedTable(
        _ raw: String,
        delimiter: Character
    ) -> (headers: [String], rows: [[String]]) {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return ([], []) }

        let parsedRows = lines.map { line in
            line
                .split(separator: delimiter, omittingEmptySubsequences: false)
                .map { clippedCell(String($0)) }
        }
        guard let first = parsedRows.first else { return ([], []) }
        let dataRows = parsedRows.dropFirst().map(Array.init)
        return (headers: first, rows: dataRows)
    }

    private static func deduplicateSheets(_ sheets: [Sheet]) -> [Sheet] {
        var seen = Set<String>()
        var result: [Sheet] = []
        for sheet in sheets {
            let signature = signatureForSheet(sheet)
            if seen.contains(signature) { continue }
            seen.insert(signature)
            result.append(sheet)
        }
        return result
    }

    private static func signatureForSheet(_ sheet: Sheet) -> String {
        let rowSample = sheet.rows.prefix(4).map { $0.joined(separator: "|") }.joined(separator: "\n")
        return "\(sheet.headers.joined(separator: "|"))\n\(rowSample)"
    }

    private static func ensureUniqueSheetNames(_ sheets: [Sheet]) -> [Sheet] {
        var used = Set<String>()
        var result: [Sheet] = []

        for sheet in sheets {
            var base = sanitizeSheetName(sheet.name)
            if base.isEmpty {
                base = "Sheet"
            }
            var candidate = base
            var index = 2
            while used.contains(candidate.lowercased()) {
                let suffix = "-\(index)"
                let allowed = max(1, 31 - suffix.count)
                candidate = String(base.prefix(allowed)) + suffix
                index += 1
            }
            used.insert(candidate.lowercased())
            result.append(
                Sheet(
                    name: candidate,
                    headers: sheet.headers,
                    rows: sheet.rows
                )
            )
        }
        return result
    }

    private static func sanitizeSheetName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = "Sheet"
        }
        let invalid = CharacterSet(charactersIn: "[]:*?/\\")
        text = String(text.unicodeScalars.map { scalar in
            invalid.contains(scalar) ? "-" : Character(scalar)
        })
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if text.isEmpty {
            text = "Sheet"
        }
        return String(text.prefix(31))
    }

    private static func clippedCell(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCellLength else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: maxCellLength)
        return String(trimmed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static let pythonGeneratorScript = #"""
import json
import os
import re
import zipfile
from io import BytesIO
from xml.etree import ElementTree as ET

CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
SHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
XML_NS = "http://www.w3.org/XML/1998/namespace"

ET.register_namespace("", CT_NS)
ET.register_namespace("", REL_NS)
ET.register_namespace("", SHEET_NS)
ET.register_namespace("r", R_NS)


def parse_rid(raw):
    matched = re.match(r"rId(\d+)$", raw or "")
    return int(matched.group(1)) if matched else 0


def col_name(index):
    result = ""
    n = index
    while n > 0:
        n, remainder = divmod(n - 1, 26)
        result = chr(65 + remainder) + result
    return result


def build_sheet_xml(rows):
    worksheet = ET.Element(f"{{{SHEET_NS}}}worksheet")
    sheet_data = ET.SubElement(worksheet, f"{{{SHEET_NS}}}sheetData")

    for row_index, row in enumerate(rows, start=1):
        row_node = ET.SubElement(sheet_data, f"{{{SHEET_NS}}}row", {"r": str(row_index)})
        for col_index, value in enumerate(row, start=1):
            text = "" if value is None else str(value)
            if text == "":
                continue
            cell_ref = f"{col_name(col_index)}{row_index}"
            cell = ET.SubElement(row_node, f"{{{SHEET_NS}}}c", {"r": cell_ref, "t": "inlineStr"})
            inline = ET.SubElement(cell, f"{{{SHEET_NS}}}is")
            text_node = ET.SubElement(inline, f"{{{SHEET_NS}}}t")
            if text.strip() != text:
                text_node.set(f"{{{XML_NS}}}space", "preserve")
            text_node.text = text

    return ET.tostring(worksheet, encoding="utf-8", xml_declaration=True)


def update_content_types(entries, sheet_count):
    root = ET.fromstring(entries["[Content_Types].xml"])
    for node in list(root):
        if node.tag == f"{{{CT_NS}}}Override" and node.attrib.get("PartName", "").startswith("/xl/worksheets/sheet"):
            root.remove(node)
    for index in range(1, sheet_count + 1):
        override = ET.Element(f"{{{CT_NS}}}Override")
        override.set("PartName", f"/xl/worksheets/sheet{index}.xml")
        override.set("ContentType", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")
        root.append(override)
    entries["[Content_Types].xml"] = ET.tostring(root, encoding="utf-8", xml_declaration=True)


def update_workbook_rels(entries, sheet_count):
    root = ET.fromstring(entries["xl/_rels/workbook.xml.rels"])
    for relation in list(root):
        if relation.attrib.get("Type", "").endswith("/worksheet"):
            root.remove(relation)

    max_existing = 0
    for relation in root:
        max_existing = max(max_existing, parse_rid(relation.attrib.get("Id", "")))

    relation_ids = []
    for offset in range(sheet_count):
        rid = f"rId{max_existing + offset + 1}"
        relation = ET.Element(f"{{{REL_NS}}}Relationship")
        relation.set("Id", rid)
        relation.set("Type", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet")
        relation.set("Target", f"worksheets/sheet{offset + 1}.xml")
        root.append(relation)
        relation_ids.append(rid)

    entries["xl/_rels/workbook.xml.rels"] = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    return relation_ids


def update_workbook(entries, sheet_names, relation_ids):
    root = ET.fromstring(entries["xl/workbook.xml"])
    sheets_node = root.find(f"{{{SHEET_NS}}}sheets")
    if sheets_node is None:
        sheets_node = ET.SubElement(root, f"{{{SHEET_NS}}}sheets")
    else:
        for child in list(sheets_node):
            sheets_node.remove(child)

    for index, (name, relation_id) in enumerate(zip(sheet_names, relation_ids), start=1):
        sheet_node = ET.SubElement(sheets_node, f"{{{SHEET_NS}}}sheet")
        sheet_node.set("name", name)
        sheet_node.set("sheetId", str(index))
        sheet_node.set(f"{{{R_NS}}}id", relation_id)

    entries["xl/workbook.xml"] = ET.tostring(root, encoding="utf-8", xml_declaration=True)


def rebuild_worksheets(entries, sheets):
    for name in list(entries.keys()):
        if name.startswith("xl/worksheets/sheet"):
            entries.pop(name, None)

    for index, sheet in enumerate(sheets, start=1):
        entries[f"xl/worksheets/sheet{index}.xml"] = build_sheet_xml(sheet.get("rows") or [])


def main():
    payload = json.loads(sys.stdin.read() or "{}")
    template_path = (payload.get("templatePath") or "").strip()
    output_path = (payload.get("outputPath") or "").strip()
    sheets = payload.get("sheets") or []

    if not template_path:
        raise ValueError("template_path_missing")
    if not output_path:
        raise ValueError("output_path_missing")
    if not sheets:
        sheets = [{"name": "Sheet1", "rows": [["No Data"]]}]

    with open(template_path, "rb") as f:
        template_data = f.read()
    with zipfile.ZipFile(BytesIO(template_data), "r") as zin:
        entries = {name: zin.read(name) for name in zin.namelist()}

    sheet_count = len(sheets)
    update_content_types(entries, sheet_count)
    relation_ids = update_workbook_rels(entries, sheet_count)
    update_workbook(entries, [sheet.get("name") or f"Sheet{i+1}" for i, sheet in enumerate(sheets)], relation_ids)
    rebuild_worksheets(entries, sheets)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as zout:
        for name in sorted(entries.keys()):
            zout.writestr(name, entries[name])

    row_count = 0
    for sheet in sheets:
        rows = sheet.get("rows") or []
        row_count += max(0, len(rows) - 1)

    print("IEXA_EXCEL_BUILD_OK")
    print("sheets=" + str(sheet_count))
    print("rows=" + str(row_count))
    print("output_path=" + output_path)


if __name__ == "__main__":
    import sys
    main()
"""#
}
