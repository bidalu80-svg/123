import Foundation

struct PythonExecutionResult: Equatable {
    let output: String
    let exitCode: Int
}

enum PythonExecutionError: LocalizedError, Equatable {
    case emptyCode
    case unsupportedSyntax(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .emptyCode:
            return "代码为空，无法运行。"
        case .unsupportedSyntax(let message):
            return "本地运行器暂不支持：\(message)"
        case .runtime(let message):
            return "运行失败：\(message)"
        }
    }
}

final class PythonExecutionService {
    static let shared = PythonExecutionService()

    private let maxCodeLength: Int
    private let maxOutputLength: Int
    private let maxLoopSteps: Int

    static func isRunnableSnippet(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Common non-runnable fragments from AI answers.
        if trimmed.hasPrefix("self.") || trimmed.hasPrefix("cls.") {
            return false
        }
        if trimmed == "..." || trimmed.contains("\n...") {
            return false
        }

        let lines = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !lines.isEmpty else { return false }

        // Incomplete block header like "if x:" without body.
        if lines.count == 1, lines[0].hasSuffix(":") {
            return false
        }

        // Single-line instance attribute snippets are usually not runnable alone.
        if lines.count == 1,
           lines[0].hasPrefix("self.") || lines[0].hasPrefix("cls.") {
            return false
        }

        // If it contains runnable signals, allow.
        let runnableMarkers = [
            "print(",
            "input(",
            "for ",
            "while ",
            "if ",
            "def ",
            "class ",
            "import ",
            "from ",
            "if __name__",
            "="
        ]
        if runnableMarkers.contains(where: { marker in trimmed.contains(marker) }) {
            return true
        }

        // Otherwise require at least one function call shape foo(...)
        if trimmed.range(of: #"[A-Za-z_][A-Za-z0-9_]*\s*\("#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    init(
        maxCodeLength: Int = 12_000,
        maxOutputLength: Int = 20_000,
        maxLoopSteps: Int = 50_000
    ) {
        self.maxCodeLength = maxCodeLength
        self.maxOutputLength = maxOutputLength
        self.maxLoopSteps = maxLoopSteps
    }

    func runPython(code: String, stdin: String? = nil) async throws -> PythonExecutionResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PythonExecutionError.emptyCode }
        guard trimmed.count <= maxCodeLength else {
            return PythonExecutionResult(output: "代码过长（最多 \(maxCodeLength) 字符）", exitCode: 1)
        }

        if let fullPythonResult = await EmbeddedCPythonRuntime.shared.runIfAvailable(code: trimmed, stdin: stdin) {
            return fullPythonResult
        }

        let runtimeHint = await EmbeddedCPythonRuntime.shared.statusHint()

        do {
            let interpreter = LocalPythonInterpreter(
                maxOutputLength: maxOutputLength,
                maxLoopSteps: maxLoopSteps,
                stdin: stdin ?? ""
            )
            return try interpreter.execute(code: trimmed)
        } catch let error as PythonExecutionError {
            var message = error.errorDescription ?? "运行失败"
            if shouldSuggestEmbeddedRuntime(for: trimmed) {
                message += "\n\n提示：\(runtimeHint)"
            }
            return PythonExecutionResult(output: message, exitCode: 1)
        } catch {
            return PythonExecutionResult(output: "运行失败：\(error.localizedDescription)", exitCode: 1)
        }
    }

    private func shouldSuggestEmbeddedRuntime(for code: String) -> Bool {
        let lowered = code.lowercased()
        let markers = [
            "import ",
            "from ",
            "def ",
            "class ",
            "try:",
            "except ",
            "finally:",
            "with ",
            "break",
            "continue",
            "input(",
            "__name__",
            "__main__"
        ]
        return markers.contains { lowered.contains($0) }
    }
}

private final class LocalPythonInterpreter {
    private var env: [String: Value] = [:]
    private var output: [String] = []
    private var outputCount = 0
    private var steps = 0
    private var inputBuffer: [String]
    private var inputCursor = 0

    private let maxOutputLength: Int
    private let maxLoopSteps: Int

    init(maxOutputLength: Int, maxLoopSteps: Int, stdin: String) {
        self.maxOutputLength = maxOutputLength
        self.maxLoopSteps = maxLoopSteps
        self.inputBuffer = stdin.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func execute(code: String) throws -> PythonExecutionResult {
        let lines = try PythonLineParser.parse(code: code)
        _ = try runBlock(lines: lines, start: 0, indent: 0)
        let text = output.joined(separator: "\n")
        return PythonExecutionResult(output: text.isEmpty ? "执行完成（无输出）" : text, exitCode: 0)
    }

    private func runBlock(lines: [Line], start: Int, indent: Int) throws -> Int {
        var index = start

        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            if line.indent > indent {
                throw PythonExecutionError.unsupportedSyntax("第\(line.number)行缩进异常")
            }

            if line.raw == "break" || line.raw == "continue" {
                throw PythonExecutionError.unsupportedSyntax("第\(line.number)行不支持 break/continue")
            }

            if line.raw.hasPrefix("for ") {
                index = try executeFor(lines: lines, index: index)
                continue
            }

            if line.raw.hasPrefix("if ") {
                index = try executeIf(lines: lines, index: index)
                continue
            }

            if line.raw.hasPrefix("while ") {
                index = try executeWhile(lines: lines, index: index)
                continue
            }

            try executeSimple(line)
            index += 1
        }

        return index
    }

    private func executeSimple(_ line: Line) throws {
        let raw = line.raw

        if raw.hasPrefix("import ") || raw.hasPrefix("from ") || raw.hasPrefix("def ") || raw.hasPrefix("class ") {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行语法 \(raw)")
        }

        if raw.hasPrefix("print(") && raw.hasSuffix(")") {
            let inner = String(raw.dropFirst(6).dropLast())
            let parts = try splitTopLevelComma(inner)
            let values = try parts.map { try evalExpr($0, line: line.number) }
            let rendered = values.map { $0.rendered }.joined(separator: " ")
            try appendOutput(rendered)
            return
        }

        if let assign = try parseAssignment(raw, line: line.number) {
            let value = try evalExpr(assign.expr, line: line.number)
            env[assign.name] = value
            return
        }

        _ = try evalExpr(raw, line: line.number)
    }

    private func executeIf(lines: [Line], index: Int) throws -> Int {
        let line = lines[index]
        guard line.raw.hasSuffix(":") else {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行 if 缺少冒号")
        }

        let conditionExpr = String(line.raw.dropFirst(2).dropLast()).trimmingCharacters(in: .whitespaces)
        let trueStart = index + 1
        guard trueStart < lines.count, lines[trueStart].indent == line.indent + 1 else {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行 if 缺少缩进代码块")
        }

        let trueEnd = blockEnd(lines: lines, from: trueStart, indent: line.indent + 1)

        var elseStart = trueEnd
        var elseEnd = trueEnd
        if trueEnd < lines.count, lines[trueEnd].indent == line.indent, lines[trueEnd].raw == "else:" {
            elseStart = trueEnd + 1
            guard elseStart < lines.count, lines[elseStart].indent == line.indent + 1 else {
                throw PythonExecutionError.unsupportedSyntax("第\(lines[trueEnd].number)行 else 缺少缩进代码块")
            }
            elseEnd = blockEnd(lines: lines, from: elseStart, indent: line.indent + 1)
        }

        let cond = try evalExpr(conditionExpr, line: line.number).isTruthy
        if cond {
            _ = try runBlock(lines: lines, start: trueStart, indent: line.indent + 1)
        } else if elseStart < elseEnd {
            _ = try runBlock(lines: lines, start: elseStart, indent: line.indent + 1)
        }

        return elseStart < elseEnd ? elseEnd : trueEnd
    }

    private func executeWhile(lines: [Line], index: Int) throws -> Int {
        let line = lines[index]
        guard line.raw.hasSuffix(":") else {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行 while 缺少冒号")
        }

        let conditionExpr = String(line.raw.dropFirst(5).dropLast()).trimmingCharacters(in: .whitespaces)
        let bodyStart = index + 1
        guard bodyStart < lines.count, lines[bodyStart].indent == line.indent + 1 else {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行 while 缺少缩进代码块")
        }
        let end = blockEnd(lines: lines, from: bodyStart, indent: line.indent + 1)

        while try evalExpr(conditionExpr, line: line.number).isTruthy {
            steps += 1
            if steps > maxLoopSteps {
                throw PythonExecutionError.runtime("循环步数超过限制（\(maxLoopSteps)）")
            }
            _ = try runBlock(lines: lines, start: bodyStart, indent: line.indent + 1)
        }

        return end
    }

    private func executeFor(lines: [Line], index: Int) throws -> Int {
        let line = lines[index]
        guard line.raw.hasSuffix(":") else {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行 for 缺少冒号")
        }

        let body = String(line.raw.dropFirst(4).dropLast())
        let parts = body.components(separatedBy: " in ")
        guard parts.count == 2 else {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行 for 语法应为 for x in range(...):")
        }

        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let rangeExpr = parts[1].trimmingCharacters(in: .whitespaces)
        guard isIdentifier(name) else {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行循环变量名无效")
        }

        let values = try evalRange(rangeExpr, line: line.number)
        let bodyStart = index + 1
        guard bodyStart < lines.count, lines[bodyStart].indent == line.indent + 1 else {
            throw PythonExecutionError.unsupportedSyntax("第\(line.number)行 for 缺少缩进代码块")
        }
        let end = blockEnd(lines: lines, from: bodyStart, indent: line.indent + 1)

        for item in values {
            steps += 1
            if steps > maxLoopSteps {
                throw PythonExecutionError.runtime("循环步数超过限制（\(maxLoopSteps)）")
            }
            env[name] = .number(Double(item))
            _ = try runBlock(lines: lines, start: bodyStart, indent: line.indent + 1)
        }

        return end
    }

    private func blockEnd(lines: [Line], from start: Int, indent: Int) -> Int {
        var index = start
        while index < lines.count, lines[index].indent >= indent {
            index += 1
        }
        return index
    }

    private func evalRange(_ expr: String, line: Int) throws -> [Int] {
        guard expr.hasPrefix("range("), expr.hasSuffix(")") else {
            throw PythonExecutionError.unsupportedSyntax("第\(line)行 for 仅支持 range()")
        }

        let inner = String(expr.dropFirst(6).dropLast())
        let argsText = try splitTopLevelComma(inner)
        let args = try argsText.map { try evalExpr($0, line: line) }
        let ints = try args.map {
            guard let v = $0.intValue else {
                throw PythonExecutionError.runtime("第\(line)行 range 参数必须是整数")
            }
            return v
        }

        let start: Int
        let end: Int
        let step: Int
        switch ints.count {
        case 1:
            start = 0; end = ints[0]; step = 1
        case 2:
            start = ints[0]; end = ints[1]; step = 1
        case 3:
            start = ints[0]; end = ints[1]; step = ints[2]
        default:
            throw PythonExecutionError.runtime("第\(line)行 range 仅支持 1~3 个参数")
        }

        if step == 0 {
            throw PythonExecutionError.runtime("第\(line)行 range 的 step 不能为 0")
        }

        var result: [Int] = []
        var i = start
        while (step > 0 && i < end) || (step < 0 && i > end) {
            result.append(i)
            if result.count > maxLoopSteps {
                throw PythonExecutionError.runtime("第\(line)行 range 结果过大")
            }
            i += step
        }
        return result
    }

    private func parseAssignment(_ raw: String, line: Int) throws -> (name: String, expr: String)? {
        if raw.contains("==") || raw.contains("!=") || raw.contains("<=") || raw.contains(">=") {
            return nil
        }

        guard let range = raw.range(of: "=") else { return nil }
        let left = raw[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = raw[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else {
            throw PythonExecutionError.unsupportedSyntax("第\(line)行赋值语法错误")
        }
        guard isIdentifier(String(left)) else {
            throw PythonExecutionError.unsupportedSyntax("第\(line)行变量名无效")
        }
        return (String(left), String(right))
    }

    private func isIdentifier(_ value: String) -> Bool {
        guard let first = value.first else { return false }
        if !(first.isLetter || first == "_") { return false }
        return value.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func appendOutput(_ text: String) throws {
        let extra = text.count + (output.isEmpty ? 0 : 1)
        if outputCount + extra > maxOutputLength {
            throw PythonExecutionError.runtime("输出过长（超过 \(maxOutputLength) 字符）")
        }
        outputCount += extra
        output.append(text)
    }

    private func evalExpr(_ rawExpr: String, line: Int) throws -> Value {
        let expr = rawExpr.trimmingCharacters(in: .whitespacesAndNewlines)
        if expr.isEmpty {
            return .none
        }

        if expr.hasPrefix("\"") && expr.hasSuffix("\""), expr.count >= 2 {
            return .string(String(expr.dropFirst().dropLast()))
        }
        if expr.hasPrefix("'") && expr.hasSuffix("'"), expr.count >= 2 {
            return .string(String(expr.dropFirst().dropLast()))
        }

        if let number = Double(expr) {
            return .number(number)
        }

        if expr == "True" { return .bool(true) }
        if expr == "False" { return .bool(false) }
        if expr == "None" { return .none }

        if expr.hasPrefix("input("), expr.hasSuffix(")") {
            let inner = String(expr.dropFirst(6).dropLast())
            let promptExpr = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if !promptExpr.isEmpty {
                let prompt = try evalExpr(promptExpr, line: line).rendered
                if !prompt.isEmpty {
                    try appendOutput(prompt)
                }
            }
            return .string(readInputLine())
        }

        if expr.hasPrefix("len("), expr.hasSuffix(")") {
            let inner = String(expr.dropFirst(4).dropLast())
            let value = try evalExpr(inner, line: line)
            switch value {
            case .string(let text): return .number(Double(text.count))
            case .list(let values): return .number(Double(values.count))
            default:
                throw PythonExecutionError.runtime("第\(line)行 len() 仅支持字符串或列表")
            }
        }

        if expr.contains(" and ") {
            let parts = expr.components(separatedBy: " and ")
            let values = try parts.map { try evalExpr($0, line: line).isTruthy }
            return .bool(values.allSatisfy { $0 })
        }

        if expr.contains(" or ") {
            let parts = expr.components(separatedBy: " or ")
            let values = try parts.map { try evalExpr($0, line: line).isTruthy }
            return .bool(values.contains(true))
        }

        for op in ["==", "!=", ">=", "<=", ">", "<"] {
            if let range = expr.range(of: op) {
                let left = try evalExpr(String(expr[..<range.lowerBound]), line: line)
                let right = try evalExpr(String(expr[range.upperBound...]), line: line)
                return .bool(compare(left: left, right: right, op: op))
            }
        }

        if let calc = try evalArithmetic(expr, line: line) {
            return .number(calc)
        }

        if expr.hasPrefix("["), expr.hasSuffix("]") {
            let inner = String(expr.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .list([])
            }
            let parts = try splitTopLevelComma(inner)
            let values = try parts.map { try evalExpr($0, line: line) }
            return .list(values)
        }

        if let value = env[expr] {
            return value
        }

        throw PythonExecutionError.unsupportedSyntax("第\(line)行表达式无法解析：\(expr)")
    }

    private func evalArithmetic(_ expr: String, line: Int) throws -> Double? {
        let parser = ArithmeticParser(
            source: expr,
            resolveVariable: { [weak self] name in
                guard let self, let value = self.env[name], let number = value.numberValue else {
                    return nil
                }
                return number
            }
        )
        do {
            return try parser.parse()
        } catch let error as ArithmeticParserError {
            switch error {
            case .unsupported:
                return nil
            case .runtime(let message):
                throw PythonExecutionError.runtime("第\(line)行\(message)")
            }
        }
    }

    private func compare(left: Value, right: Value, op: String) -> Bool {
        if let l = left.numberValue, let r = right.numberValue {
            switch op {
            case "==": return l == r
            case "!=": return l != r
            case ">=": return l >= r
            case "<=": return l <= r
            case ">": return l > r
            case "<": return l < r
            default: return false
            }
        }

        let l = left.rendered
        let r = right.rendered
        switch op {
        case "==": return l == r
        case "!=": return l != r
        case ">=": return l >= r
        case "<=": return l <= r
        case ">": return l > r
        case "<": return l < r
        default: return false
        }
    }

    private func splitTopLevelComma(_ raw: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inSingle = false
        var inDouble = false

        for ch in raw {
            if ch == "'", !inDouble { inSingle.toggle(); current.append(ch); continue }
            if ch == "\"", !inSingle { inDouble.toggle(); current.append(ch); continue }
            if inSingle || inDouble { current.append(ch); continue }

            if ch == "(" || ch == "[" { depth += 1; current.append(ch); continue }
            if ch == ")" || ch == "]" { depth -= 1; current.append(ch); continue }

            if ch == ",", depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
                continue
            }

            current.append(ch)
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private func readInputLine() -> String {
        guard inputCursor < inputBuffer.count else { return "" }
        defer { inputCursor += 1 }
        return inputBuffer[inputCursor]
    }
}

private struct Line {
    let number: Int
    let indent: Int
    let raw: String
}

private enum Value: Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case list([Value])
    case none

    var numberValue: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? {
        guard let n = numberValue, n.rounded() == n else { return nil }
        return Int(n)
    }

    var isTruthy: Bool {
        switch self {
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .bool(let b): return b
        case .list(let values): return !values.isEmpty
        case .none: return false
        }
    }

    var rendered: String {
        switch self {
        case .number(let n):
            if n.rounded() == n { return String(Int(n)) }
            return String(n)
        case .string(let s): return s
        case .bool(let b): return b ? "True" : "False"
        case .list(let values):
            return "[" + values.map { $0.rendered }.joined(separator: ", ") + "]"
        case .none: return "None"
        }
    }
}

private enum PythonLineParser {
    static func parse(code: String) throws -> [Line] {
        let normalized = code.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var result: [Line] = []
        for (i, rawLine) in rawLines.enumerated() {
            let lineNumber = i + 1
            let text = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let spaces = text.prefix { $0 == " " }.count
            if spaces % 4 != 0 {
                throw PythonExecutionError.unsupportedSyntax("第\(lineNumber)行缩进请使用 4 的倍数空格")
            }
            let start = text.index(text.startIndex, offsetBy: spaces)
            let raw = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            result.append(Line(number: lineNumber, indent: spaces / 4, raw: raw))
        }
        return result
    }
}

private enum ArithmeticParserError: Error {
    case unsupported
    case runtime(String)
}

private struct ArithmeticParser {
    let source: String
    let resolveVariable: (String) -> Double?

    private var tokens: [String] {
        var result: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }

        for ch in source {
            if ch.isWhitespace { flush(); continue }
            if "+-*/()".contains(ch) {
                flush()
                result.append(String(ch))
                continue
            }
            current.append(ch)
        }
        flush()
        return result
    }

    func parse() throws -> Double {
        var index = 0
        let t = tokens
        if t.isEmpty { throw ArithmeticParserError.unsupported }

        func parseExpression() throws -> Double {
            var value = try parseTerm()
            while index < t.count {
                let op = t[index]
                if op != "+" && op != "-" { break }
                index += 1
                let rhs = try parseTerm()
                value = (op == "+") ? (value + rhs) : (value - rhs)
            }
            return value
        }

        func parseTerm() throws -> Double {
            var value = try parseFactor()
            while index < t.count {
                let op = t[index]
                if op != "*" && op != "/" { break }
                index += 1
                let rhs = try parseFactor()
                if op == "*" {
                    value *= rhs
                } else {
                    if rhs == 0 { throw ArithmeticParserError.runtime("除数不能为 0") }
                    value /= rhs
                }
            }
            return value
        }

        func parseFactor() throws -> Double {
            guard index < t.count else { throw ArithmeticParserError.unsupported }
            let token = t[index]

            if token == "(" {
                index += 1
                let value = try parseExpression()
                guard index < t.count, t[index] == ")" else { throw ArithmeticParserError.unsupported }
                index += 1
                return value
            }

            if token == "+" || token == "-" {
                index += 1
                let value = try parseFactor()
                return token == "-" ? -value : value
            }

            index += 1
            if let number = Double(token) {
                return number
            }
            if let value = resolveVariable(token) {
                return value
            }
            throw ArithmeticParserError.unsupported
        }

        let value = try parseExpression()
        if index != t.count { throw ArithmeticParserError.unsupported }
        return value
    }
}
