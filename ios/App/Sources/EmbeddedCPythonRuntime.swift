import Foundation
import Darwin

actor EmbeddedCPythonRuntime {
    static let shared = EmbeddedCPythonRuntime()

    private typealias PyIsInitializedFn = @convention(c) () -> Int32
    private typealias PyInitializeFn = @convention(c) () -> Void
    private typealias PyRunSimpleStringFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias PyGILStateEnsureFn = @convention(c) () -> Int32
    private typealias PyGILStateReleaseFn = @convention(c) (Int32) -> Void

    private var handle: UnsafeMutableRawPointer?
    private var pyIsInitialized: PyIsInitializedFn?
    private var pyInitialize: PyInitializeFn?
    private var pyRunSimpleString: PyRunSimpleStringFn?
    private var pyGILStateEnsure: PyGILStateEnsureFn?
    private var pyGILStateRelease: PyGILStateReleaseFn?
    private var prepared = false
    private var cachedStatusHint = "未检测到嵌入 CPython 运行时，当前使用兼容模式。"
    private let runtimeQueue = DispatchQueue(label: "chatapp.embedded-python.runtime")

    func runIfAvailable(code: String, stdin: String?) -> PythonExecutionResult? {
        runOnRuntimeQueue {
            runIfAvailableLocked(code: code, stdin: stdin)
        }
    }

    func statusHint() -> String {
        runOnRuntimeQueue {
            _ = prepareIfNeededLocked()
            return cachedStatusHint
        }
    }

    // CPython C API is thread-sensitive. We execute all embedded-runtime calls
    // on one serial queue and acquire/release the GIL around each execution.
    // This prevents thread-state mismatches that can surface on subsequent runs.
    private func runOnRuntimeQueue<T>(_ block: () -> T) -> T {
        runtimeQueue.sync(execute: block)
    }

    private func runIfAvailableLocked(code: String, stdin: String?) -> PythonExecutionResult? {
        guard prepareIfNeededLocked() else { return nil }
        guard let pyRunSimpleString, let pyGILStateEnsure, let pyGILStateRelease else {
            cachedStatusHint = "嵌入 CPython 已加载，但缺少运行入口符号。"
            return nil
        }

        do {
            try ensureInitializedLocked()

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("py-out-\(UUID().uuidString).txt")
            let exitURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("py-exit-\(UUID().uuidString).txt")
            defer {
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: exitURL)
            }

            let script = makeHarnessScript(
                userCode: code,
                stdinText: stdin ?? "",
                outputPath: outputURL.path,
                exitPath: exitURL.path
            )

            let gilState = pyGILStateEnsure()
            let rc = script.withCString { pyRunSimpleString($0) }
            pyGILStateRelease(gilState)

            if rc != 0 {
                return PythonExecutionResult(
                    output: "CPython 执行失败（初始化或脚本桥接失败，rc=\(rc)）。",
                    exitCode: 1
                )
            }

            let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            let exitRaw = (try? String(contentsOf: exitURL, encoding: .utf8)) ?? "0"
            let exitCode = Int(exitRaw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let normalized = output.trimmingCharacters(in: .newlines).isEmpty ? "执行完成（无输出）" : output

            return PythonExecutionResult(output: normalized, exitCode: exitCode)
        } catch {
            return PythonExecutionResult(output: "CPython 运行失败：\(error.localizedDescription)", exitCode: 1)
        }
    }

    private func prepareIfNeededLocked() -> Bool {
        if prepared {
            return handle != nil
                && pyRunSimpleString != nil
                && pyGILStateEnsure != nil
                && pyGILStateRelease != nil
        }
        prepared = true

        let candidates = candidateLibraryPaths()
        for path in candidates {
            guard let h = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else { continue }
            handle = h
            pyIsInitialized = loadSymbol("Py_IsInitialized", as: PyIsInitializedFn.self)
            pyInitialize = loadSymbol("Py_Initialize", as: PyInitializeFn.self)
            pyRunSimpleString = loadSymbol("PyRun_SimpleString", as: PyRunSimpleStringFn.self)
            pyGILStateEnsure = loadSymbol("PyGILState_Ensure", as: PyGILStateEnsureFn.self)
            pyGILStateRelease = loadSymbol("PyGILState_Release", as: PyGILStateReleaseFn.self)

            if pyIsInitialized != nil,
               pyInitialize != nil,
               pyRunSimpleString != nil,
               pyGILStateEnsure != nil,
               pyGILStateRelease != nil {
                cachedStatusHint = "已启用嵌入 CPython 运行时。"
                configurePythonEnvironment()
                return true
            }
            dlclose(h)
            handle = nil
            pyIsInitialized = nil
            pyInitialize = nil
            pyRunSimpleString = nil
            pyGILStateEnsure = nil
            pyGILStateRelease = nil
        }

        cachedStatusHint = "未检测到嵌入 CPython（Python.framework 未集成到 App）。"
        return false
    }

    private func ensureInitializedLocked() throws {
        guard let pyIsInitialized, let pyInitialize else {
            throw NSError(domain: "EmbeddedCPython", code: 1001, userInfo: [NSLocalizedDescriptionKey: "CPython 符号缺失"])
        }
        if pyIsInitialized() == 0 {
            pyInitialize()
        }
    }

    private func configurePythonEnvironment() {
        setenv("PYTHONUTF8", "1", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONIOENCODING", "utf-8", 1)

        guard let resourceURL = Bundle.main.resourceURL else { return }
        let runtimeRoot = resourceURL.appendingPathComponent("PythonRuntime")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: runtimeRoot.path, isDirectory: &isDir), isDir.boolValue {
            setenv("PYTHONHOME", runtimeRoot.path, 1)
            let libDir = runtimeRoot.appendingPathComponent("lib")
            if let entries = try? FileManager.default.contentsOfDirectory(at: libDir, includingPropertiesForKeys: nil) {
                if let versionDir = entries.first(where: { $0.lastPathComponent.hasPrefix("python3") }) {
                    setenv("PYTHONPATH", versionDir.path, 1)
                }
            }
        }
    }

    private func loadSymbol<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    private func candidateLibraryPaths() -> [String] {
        var paths: [String] = []
        if let privateFrameworks = Bundle.main.privateFrameworksPath {
            paths.append((privateFrameworks as NSString).appendingPathComponent("Python.framework/Python"))
        }
        let frameworks = Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true).path
        paths.append((frameworks as NSString).appendingPathComponent("Python.framework/Python"))
        paths.append("@rpath/Python.framework/Python")
        var deduped: [String] = []
        var seen = Set<String>()
        for path in paths where !seen.contains(path) {
            seen.insert(path)
            deduped.append(path)
        }
        return deduped
    }

    private func makeHarnessScript(userCode: String, stdinText: String, outputPath: String, exitPath: String) -> String {
        let code = pythonLiteral(userCode)
        let stdin = pythonLiteral(stdinText)
        let out = pythonLiteral(outputPath)
        let exit = pythonLiteral(exitPath)
        return """
import io
import sys
import traceback
import types

_MAX_OUT = 12000

_buf = io.StringIO()
_old_out = sys.stdout
_old_err = sys.stderr
_old_in = sys.stdin
_exit = 0

sys.stdout = _buf
sys.stderr = _buf
sys.stdin = io.StringIO(\(stdin))
try:
    # Pythonista compatibility: provide a lightweight "notification" shim.
    _notification = types.ModuleType("notification")
    def _notification_schedule(message="", delay=0, sound_name=None, action_url=None, title=""):
        _msg = str(message or "")
        _title = str(title or "")
        _delay = str(delay or 0)
        _prefix = "[提醒]"
        if _title:
            _prefix = _prefix + " " + _title
        if _msg:
            _prefix = _prefix + " " + _msg
        print(_prefix + " (兼容模式，delay=" + _delay + "s)")
        return {"scheduled": True, "message": _msg, "delay": delay}
    def _notification_cancel_all():
        return None
    _notification.schedule = _notification_schedule
    _notification.cancel_all = _notification_cancel_all
    _notification.cancel = _notification_cancel_all
    _notification.set_badge = lambda *_args, **_kwargs: None
    _notification.get_scheduled = lambda: []
    sys.modules.setdefault("notification", _notification)

    _globals = {"__name__": "__main__"}
    exec(compile(\(code), "<chatapp>", "exec"), _globals, _globals)
except SystemExit as e:
    try:
        _exit = int(getattr(e, "code", 0) or 0)
    except Exception:
        _exit = 1
except BaseException:
    _exit = 1
    traceback.print_exc()
finally:
    sys.stdout = _old_out
    sys.stderr = _old_err
    sys.stdin = _old_in

_text = _buf.getvalue()
if len(_text) > _MAX_OUT:
    _text = _text[:_MAX_OUT] + "\\n...[输出过长，已截断]"

with open(\(out), "w", encoding="utf-8") as f:
    f.write(_text)
with open(\(exit), "w", encoding="utf-8") as f:
    f.write(str(_exit))
"""
    }

    private func pythonLiteral(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "\\", with: "\\\\")
        text = text.replacingOccurrences(of: "'", with: "\\'")
        text = text.replacingOccurrences(of: "\n", with: "\\n")
        text = text.replacingOccurrences(of: "\r", with: "\\r")
        text = text.replacingOccurrences(of: "\t", with: "\\t")
        return "'\(text)'"
    }
}
