import Foundation
import Darwin

actor EmbeddedCPythonRuntime {
    static let shared = EmbeddedCPythonRuntime()
    private static let maxInteractiveOutputLength = 24_000

    private typealias PyIsInitializedFn = @convention(c) () -> Int32
    private typealias PyInitializeFn = @convention(c) () -> Void
    private typealias PyRunSimpleStringFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias PyGILStateEnsureFn = @convention(c) () -> Int32
    private typealias PyGILStateReleaseFn = @convention(c) (Int32) -> Void
    private typealias PyEvalSaveThreadFn = @convention(c) () -> UnsafeMutableRawPointer?

    private var handle: UnsafeMutableRawPointer?
    private var pyIsInitialized: PyIsInitializedFn?
    private var pyInitialize: PyInitializeFn?
    private var pyRunSimpleString: PyRunSimpleStringFn?
    private var pyGILStateEnsure: PyGILStateEnsureFn?
    private var pyGILStateRelease: PyGILStateReleaseFn?
    private var pyEvalSaveThread: PyEvalSaveThreadFn?
    private var prepared = false
    private var didReleaseInitialGIL = false
    private var cachedStatusHint = "未检测到嵌入 CPython 运行时，当前使用兼容模式。"
    private let runtimeQueue = DispatchQueue(label: "chatapp.embedded-python.runtime")

    func runIfAvailable(code: String, stdin: String?) -> PythonExecutionResult? {
        runOnRuntimeQueue {
            runIfAvailableLocked(code: code, stdin: stdin)
        }
    }

    func startInteractiveSession(code: String) -> PythonInteractiveSessionSnapshot? {
        runOnRuntimeQueue {
            startInteractiveSessionLocked(code: code)
        }
    }

    func pollInteractiveSession(sessionID: String) -> PythonInteractiveSessionSnapshot? {
        runOnRuntimeQueue {
            pollInteractiveSessionLocked(sessionID: sessionID)
        }
    }

    func sendInteractiveInput(sessionID: String, input: String) -> PythonInteractiveSessionSnapshot? {
        runOnRuntimeQueue {
            sendInteractiveInputLocked(sessionID: sessionID, input: input)
        }
    }

    func stopInteractiveSession(sessionID: String) -> PythonInteractiveSessionSnapshot? {
        runOnRuntimeQueue {
            stopInteractiveSessionLocked(sessionID: sessionID)
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

    private func startInteractiveSessionLocked(code: String) -> PythonInteractiveSessionSnapshot? {
        guard prepareIfNeededLocked() else { return nil }
        do {
            try ensureInitializedLocked()
            let sessionID = UUID().uuidString
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("py-interactive-start-\(sessionID).json")
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let script = interactiveBootstrapScript() + """
_chatapp_session_id = \(pythonLiteral(sessionID))
_chatapp_code = \(pythonLiteral(code))
_chatapp_out = \(pythonLiteral(outputURL.path))
if _chatapp_session_id in _chatapp_interactive_sessions:
    _chatapp_close_session(_chatapp_session_id)
_chatapp_start_session(_chatapp_session_id, _chatapp_code)
with open(_chatapp_out, "w", encoding="utf-8") as _chatapp_file:
    _chatapp_file.write(json.dumps(_chatapp_snapshot(_chatapp_session_id), ensure_ascii=False))
"""

            guard runPythonBridgeScriptLocked(script) else { return nil }
            return readInteractiveSnapshot(from: outputURL)
        } catch {
            return nil
        }
    }

    private func pollInteractiveSessionLocked(sessionID: String) -> PythonInteractiveSessionSnapshot? {
        runInteractiveCommandLocked(
            sessionID: sessionID,
            command: """
with open(_chatapp_out, "w", encoding="utf-8") as _chatapp_file:
    _chatapp_file.write(json.dumps(_chatapp_snapshot(_chatapp_session_id), ensure_ascii=False))
"""
        )
    }

    private func sendInteractiveInputLocked(sessionID: String, input: String) -> PythonInteractiveSessionSnapshot? {
        runInteractiveCommandLocked(
            sessionID: sessionID,
            command: """
_chatapp_push_input(_chatapp_session_id, \(pythonLiteral(input)))
with open(_chatapp_out, "w", encoding="utf-8") as _chatapp_file:
    _chatapp_file.write(json.dumps(_chatapp_snapshot(_chatapp_session_id), ensure_ascii=False))
"""
        )
    }

    private func stopInteractiveSessionLocked(sessionID: String) -> PythonInteractiveSessionSnapshot? {
        runInteractiveCommandLocked(
            sessionID: sessionID,
            command: """
_chatapp_close_session(_chatapp_session_id)
with open(_chatapp_out, "w", encoding="utf-8") as _chatapp_file:
    _chatapp_file.write(json.dumps(_chatapp_snapshot(_chatapp_session_id), ensure_ascii=False))
"""
        )
    }

    private func runInteractiveCommandLocked(
        sessionID: String,
        command: String
    ) -> PythonInteractiveSessionSnapshot? {
        guard prepareIfNeededLocked() else { return nil }
        do {
            try ensureInitializedLocked()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("py-interactive-\(sessionID)-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let script = interactiveBootstrapScript() + """
_chatapp_session_id = \(pythonLiteral(sessionID))
_chatapp_out = \(pythonLiteral(outputURL.path))
\(command)
"""

            guard runPythonBridgeScriptLocked(script) else { return nil }
            return readInteractiveSnapshot(from: outputURL)
        } catch {
            return nil
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
            pyEvalSaveThread = loadSymbol("PyEval_SaveThread", as: PyEvalSaveThreadFn.self)

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
            pyEvalSaveThread = nil
        }

        cachedStatusHint = "未检测到嵌入 CPython（Python.framework 未集成到 App）。"
        return false
    }

    private func ensureInitializedLocked() throws {
        guard let pyIsInitialized, let pyInitialize else {
            throw NSError(domain: "EmbeddedCPython", code: 1001, userInfo: [NSLocalizedDescriptionKey: "CPython 符号缺失"])
        }
        let wasInitialized = pyIsInitialized() != 0
        if !wasInitialized {
            pyInitialize()
        }
        // Py_Initialize leaves the current OS thread holding the GIL.
        // A serial DispatchQueue is not guaranteed to reuse the same thread forever,
        // so later executions can hang once GCD hops to a different worker thread.
        // Releasing the initial thread state here lets every run reacquire the GIL
        // cleanly through PyGILState_Ensure / PyGILState_Release.
        if !wasInitialized, !didReleaseInitialGIL, let pyEvalSaveThread {
            _ = pyEvalSaveThread()
            didReleaseInitialGIL = true
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
                    var pythonPaths: [String] = [versionDir.path]

                    let sitePackagesDir = versionDir.appendingPathComponent("site-packages", isDirectory: true)
                    if FileManager.default.fileExists(atPath: sitePackagesDir.path, isDirectory: &isDir), isDir.boolValue {
                        pythonPaths.append(sitePackagesDir.path)
                    }

                    let distPackagesDir = versionDir.appendingPathComponent("dist-packages", isDirectory: true)
                    if FileManager.default.fileExists(atPath: distPackagesDir.path, isDirectory: &isDir), isDir.boolValue {
                        pythonPaths.append(distPackagesDir.path)
                    }

                    if let existing = ProcessInfo.processInfo.environment["PYTHONPATH"]?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !existing.isEmpty {
                        pythonPaths.append(existing)
                    }

                    let joined = pythonPaths
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: ":")
                    if !joined.isEmpty {
                        setenv("PYTHONPATH", joined, 1)
                    }
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

    private func runPythonBridgeScriptLocked(_ script: String) -> Bool {
        guard let pyRunSimpleString, let pyGILStateEnsure, let pyGILStateRelease else {
            cachedStatusHint = "嵌入 CPython 已加载，但缺少运行入口符号。"
            return false
        }

        let gilState = pyGILStateEnsure()
        let rc = script.withCString { pyRunSimpleString($0) }
        pyGILStateRelease(gilState)
        return rc == 0
    }

    private func readInteractiveSnapshot(from url: URL) -> PythonInteractiveSessionSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let sessionID = (object["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionID.isEmpty else { return nil }
        let output = object["output"] as? String ?? ""
        let waiting = object["waiting"] as? Bool ?? false
        let finished = object["finished"] as? Bool ?? false
        let exitCode = object["exit_code"] as? Int

        return PythonInteractiveSessionSnapshot(
            sessionID: sessionID,
            output: output,
            isWaitingForInput: waiting,
            isFinished: finished,
            exitCode: exitCode
        )
    }

    private func interactiveBootstrapScript() -> String {
        let maxOutput = Self.maxInteractiveOutputLength
        return """
import json
import sys
import traceback
import threading
import types

if "_chatapp_interactive_sessions" not in globals():
    _chatapp_interactive_sessions = {}

if "_chatapp_make_notification_shim" not in globals():
    def _chatapp_make_notification_shim():
        _notification = types.ModuleType("notification")
        def _notification_schedule(message="", delay=0, sound_name=None, action_url=None, title=""):
            _msg = str(message or "")
            _title = str(title or "")
            _prefix = "[提醒]"
            if _title:
                _prefix = _prefix + " " + _title
            if _msg:
                _prefix = _prefix + " " + _msg
            return {"scheduled": True, "message": _msg, "delay": delay}
        _notification.schedule = _notification_schedule
        _notification.cancel_all = lambda: None
        _notification.cancel = lambda *_args, **_kwargs: None
        _notification.set_badge = lambda *_args, **_kwargs: None
        _notification.get_scheduled = lambda: []
        return _notification

if "_ChatAppInteractiveStream" not in globals():
    class _ChatAppInteractiveStream:
        def __init__(self, session):
            self.session = session
        def write(self, data):
            text = "" if data is None else str(data)
            if not text:
                return 0
            with self.session["condition"]:
                self.session["output"] += text
                if len(self.session["output"]) > \(maxOutput):
                    self.session["output"] = self.session["output"][-\(maxOutput):]
                self.session["condition"].notify_all()
            return len(text)
        def flush(self):
            return None
        def isatty(self):
            return True

if "_ChatAppInteractiveInput" not in globals():
    class _ChatAppInteractiveInput:
        def __init__(self, session):
            self.session = session
        def readline(self, *args):
            with self.session["condition"]:
                self.session["waiting"] = True
                self.session["condition"].notify_all()
                while not self.session["closed"] and not self.session["input_queue"]:
                    self.session["condition"].wait(0.1)
                if self.session["closed"]:
                    self.session["waiting"] = False
                    self.session["condition"].notify_all()
                    return ""
                line = self.session["input_queue"].pop(0)
                self.session["waiting"] = False
                self.session["condition"].notify_all()
                return line
        def isatty(self):
            return True

if "_chatapp_snapshot" not in globals():
    def _chatapp_snapshot(session_id):
        session = _chatapp_interactive_sessions.get(session_id)
        if session is None:
            return {
                "session_id": session_id,
                "output": "",
                "waiting": False,
                "finished": True,
                "exit_code": None
            }
        with session["condition"]:
            return {
                "session_id": session_id,
                "output": session.get("output", ""),
                "waiting": bool(session.get("waiting", False)),
                "finished": bool(session.get("finished", False)),
                "exit_code": session.get("exit_code")
            }

if "_chatapp_push_input" not in globals():
    def _chatapp_push_input(session_id, text):
        session = _chatapp_interactive_sessions.get(session_id)
        if session is None:
            return
        payload = str(text if text is not None else "")
        if not payload.endswith("\\n"):
            payload += "\\n"
        with session["condition"]:
            session["input_queue"].append(payload)
            session["condition"].notify_all()

if "_chatapp_close_session" not in globals():
    def _chatapp_close_session(session_id):
        session = _chatapp_interactive_sessions.get(session_id)
        if session is None:
            return
        with session["condition"]:
            session["closed"] = True
            session["waiting"] = False
            session["condition"].notify_all()
        thread = session.get("thread")
        thread_id = getattr(thread, "ident", None)
        if thread_id:
            try:
                import ctypes
                res = ctypes.pythonapi.PyThreadState_SetAsyncExc(
                    ctypes.c_ulong(thread_id),
                    ctypes.py_object(SystemExit)
                )
                if res > 1:
                    ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_ulong(thread_id), None)
            except Exception:
                pass

if "_chatapp_session_runner" not in globals():
    def _chatapp_session_runner(session_id, code):
        session = _chatapp_interactive_sessions.get(session_id)
        if session is None:
            return
        old_out = sys.stdout
        old_err = sys.stderr
        old_in = sys.stdin
        exit_code = 0
        sys.stdout = _ChatAppInteractiveStream(session)
        sys.stderr = _ChatAppInteractiveStream(session)
        sys.stdin = _ChatAppInteractiveInput(session)
        try:
            sys.modules.setdefault("notification", _chatapp_make_notification_shim())
            globals_map = {"__name__": "__main__"}
            exec(compile(code, "<chatapp-interactive>", "exec"), globals_map, globals_map)
        except SystemExit as e:
            try:
                exit_code = int(getattr(e, "code", 0) or 0)
            except Exception:
                exit_code = 1
        except BaseException:
            exit_code = 1
            traceback.print_exc()
        finally:
            sys.stdout = old_out
            sys.stderr = old_err
            sys.stdin = old_in
            with session["condition"]:
                session["finished"] = True
                session["waiting"] = False
                session["exit_code"] = exit_code
                session["condition"].notify_all()

if "_chatapp_start_session" not in globals():
    def _chatapp_start_session(session_id, code):
        session = {
            "condition": threading.Condition(),
            "input_queue": [],
            "output": "",
            "waiting": False,
            "finished": False,
            "closed": False,
            "exit_code": None,
        }
        _chatapp_interactive_sessions[session_id] = session
        thread = threading.Thread(
            target=_chatapp_session_runner,
            args=(session_id, code),
            daemon=True
        )
        session["thread"] = thread
        thread.start()
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
