import Foundation

enum PHPPreviewRuntimeBuilder {
    struct RuntimeDocument {
        let html: String
        let signature: String
    }

    private struct FilePayload: Encodable {
        let path: String
        let base64: String
        let mime: String
    }

    private struct Payload: Encodable {
        let entryPath: String
        let files: [FilePayload]
        let skippedFiles: Int
        let skippedBytes: Int
    }

    private static let maxFiles = 360
    private static let maxSingleFileBytes = 1_500_000
    private static let maxTotalBytes = 9_000_000

    static func projectContainsPHPFiles(projectRootURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: projectRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            let lowered = fileURL.pathExtension.lowercased()
            if lowered == "php" || lowered == "phtml" {
                return true
            }
        }

        return false
    }

    static func makeRuntimeDocument(
        projectRootURL: URL,
        entryFileURL: URL
    ) -> RuntimeDocument? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: projectRootURL.path) else { return nil }

        guard let enumerator = fileManager.enumerator(
            at: projectRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var payloadFiles: [FilePayload] = []
        var hasPHPFile = false
        var skippedFiles = 0
        var skippedBytes = 0
        var totalBytes = 0

        for case let fileURL as URL in enumerator {
            guard let relativePath = relativePath(of: fileURL, from: projectRootURL) else { continue }
            let normalizedPath = normalizeRelativePath(relativePath)
            guard !normalizedPath.isEmpty else { continue }
            if normalizedPath == ".iexa-latest-entry" { continue }

            let loweredExt = (normalizedPath as NSString).pathExtension.lowercased()
            if loweredExt == "php" || loweredExt == "phtml" {
                hasPHPFile = true
            }

            guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular == true else {
                continue
            }

            if payloadFiles.count >= maxFiles {
                skippedFiles += 1
                continue
            }

            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if fileSize > maxSingleFileBytes {
                skippedFiles += 1
                skippedBytes += max(0, fileSize)
                continue
            }
            if totalBytes + max(0, fileSize) > maxTotalBytes {
                skippedFiles += 1
                skippedBytes += max(0, fileSize)
                continue
            }

            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
                skippedFiles += 1
                skippedBytes += max(0, fileSize)
                continue
            }

            if data.count > maxSingleFileBytes || totalBytes + data.count > maxTotalBytes {
                skippedFiles += 1
                skippedBytes += data.count
                continue
            }

            totalBytes += data.count
            payloadFiles.append(
                FilePayload(
                    path: normalizedPath,
                    base64: data.base64EncodedString(),
                    mime: mimeType(for: normalizedPath)
                )
            )
        }

        guard hasPHPFile else { return nil }
        guard !payloadFiles.isEmpty else { return nil }

        payloadFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var entryPath = normalizeRelativePath(relativePath(of: entryFileURL, from: projectRootURL) ?? "")
        if entryPath.isEmpty {
            entryPath = payloadFiles.first(where: { isPHPPath($0.path) })?.path
                ?? payloadFiles.first(where: { isHTMLPath($0.path) })?.path
                ?? "index.php"
        }

        if !payloadFiles.contains(where: { $0.path == entryPath }) {
            if let data = try? Data(contentsOf: entryFileURL, options: [.mappedIfSafe]),
               data.count <= maxSingleFileBytes,
               totalBytes + data.count <= maxTotalBytes {
                payloadFiles.append(
                    FilePayload(
                        path: entryPath,
                        base64: data.base64EncodedString(),
                        mime: mimeType(for: entryPath)
                    )
                )
                payloadFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                totalBytes += data.count
            } else {
                return nil
            }
        }

        let payload = Payload(
            entryPath: entryPath,
            files: payloadFiles,
            skippedFiles: skippedFiles,
            skippedBytes: skippedBytes
        )
        guard let payloadData = try? JSONEncoder().encode(payload) else { return nil }
        let payloadBase64 = payloadData.base64EncodedString()

        let signature = [
            entryPath,
            String(payloadFiles.count),
            String(totalBytes),
            payloadFiles.first?.path ?? "",
            payloadFiles.last?.path ?? "",
            String(skippedFiles),
            String(skippedBytes)
        ].joined(separator: "|")

        return RuntimeDocument(
            html: runtimeHTML(payloadBase64: payloadBase64),
            signature: signature
        )
    }

    private static func runtimeHTML(payloadBase64: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>IEXA PHP 预览</title>
          <style>
            html,body{height:100%;margin:0;background:#0e1116;color:#e8ecf1;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
            .wrap{height:100%;display:flex;flex-direction:column}
            #status{padding:10px 12px;font-size:12px;line-height:1.45;border-bottom:1px solid rgba(255,255,255,.12);background:#101521}
            #status.error{color:#ffb4b4}
            #app{flex:1;border:0;width:100%;background:white}
          </style>
        </head>
        <body>
          <div class="wrap">
            <div id="status">正在初始化 PHP + SQLite 本地模拟运行时…</div>
            <iframe id="app" sandbox="allow-scripts allow-forms allow-same-origin"></iframe>
          </div>
          <script type="module">
            const PAYLOAD_BASE64 = "\(payloadBase64)";
            const RUNTIME_ORIGIN = "https://iexa.local";
            const CHANNEL_REQ = "__iexa_php_bridge_req__";
            const CHANNEL_RES = "__iexa_php_bridge_res__";
            const statusEl = document.getElementById("status");
            const appFrame = document.getElementById("app");

            function setStatus(message, isError = false) {
              statusEl.textContent = String(message || "");
              statusEl.classList.toggle("error", !!isError);
            }

            function base64ToBytes(base64) {
              if (!base64) return new Uint8Array();
              const binary = atob(base64);
              const bytes = new Uint8Array(binary.length);
              for (let i = 0; i < binary.length; i += 1) {
                bytes[i] = binary.charCodeAt(i);
              }
              return bytes;
            }

            function bytesToBase64(bytes) {
              if (!bytes || bytes.length === 0) return "";
              let result = "";
              const chunkSize = 0x8000;
              for (let i = 0; i < bytes.length; i += chunkSize) {
                const slice = bytes.subarray(i, i + chunkSize);
                result += String.fromCharCode(...slice);
              }
              return btoa(result);
            }

            function bytesToUtf8(bytes) {
              return new TextDecoder("utf-8").decode(bytes);
            }

            function escapeHTML(text) {
              return String(text)
                .replaceAll("&", "&amp;")
                .replaceAll("<", "&lt;")
                .replaceAll(">", "&gt;");
            }

            function normalizePath(raw) {
              return String(raw || "")
                .replaceAll("\\\\", "/")
                .replace(/^[/]+/, "")
                .replace(/[/]+/g, "/")
                .trim();
            }

            function isLocalURL(raw) {
              const value = String(raw || "").trim().toLowerCase();
              if (!value) return false;
              if (value.startsWith("#")) return false;
              if (value.startsWith("data:")) return false;
              if (value.startsWith("blob:")) return false;
              if (value.startsWith("javascript:")) return false;
              if (value.startsWith("mailto:")) return false;
              if (value.startsWith("tel:")) return false;
              return true;
            }

            function ensurePolyfills() {
              if (!navigator.locks || typeof navigator.locks.request !== "function") {
                const fallbackLocks = {
                  request: async (_name, callback) => callback()
                };
                try {
                  Object.defineProperty(navigator, "locks", { value: fallbackLocks, configurable: true });
                } catch {
                  navigator.locks = fallbackLocks;
                }
              }

              if (typeof Headers !== "undefined" && !Headers.prototype.getSetCookie) {
                Headers.prototype.getSetCookie = function() {
                  const raw = this.get("set-cookie");
                  return raw ? [raw] : [];
                };
              }
            }

            function decodePayload() {
              const bytes = base64ToBytes(PAYLOAD_BASE64);
              return JSON.parse(bytesToUtf8(bytes));
            }

            function requestInitFromPayload(payload) {
              const method = String(payload.method || "GET").toUpperCase();
              const headers = payload.headers || {};
              const init = { method, headers };
              if (payload.bodyBase64 && method !== "GET" && method !== "HEAD") {
                init.body = base64ToBytes(payload.bodyBase64);
              }
              return init;
            }

            function bridgeScriptText() {
              return `
              (() => {
                const CHANNEL_REQ = "__iexa_php_bridge_req__";
                const CHANNEL_RES = "__iexa_php_bridge_res__";
                const LOCAL_ORIGIN = "https://iexa.local";
                let seq = 1;
                const pending = new Map();

                function base64ToBytes(base64) {
                  if (!base64) return new Uint8Array();
                  const binary = atob(base64);
                  const bytes = new Uint8Array(binary.length);
                  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
                  return bytes;
                }

                function bytesToBase64(bytes) {
                  if (!bytes || bytes.length === 0) return "";
                  let text = "";
                  const chunk = 0x8000;
                  for (let i = 0; i < bytes.length; i += chunk) {
                    text += String.fromCharCode(...bytes.subarray(i, i + chunk));
                  }
                  return btoa(text);
                }

                function post(type, payload) {
                  parent.postMessage({ channel: CHANNEL_REQ, type, payload }, "*");
                }

                function rpc(type, payload) {
                  const id = seq++;
                  return new Promise((resolve, reject) => {
                    pending.set(id, { resolve, reject });
                    parent.postMessage({ channel: CHANNEL_REQ, type, id, payload }, "*");
                    setTimeout(() => {
                      if (pending.has(id)) {
                        pending.delete(id);
                        reject(new Error("PHP bridge timeout"));
                      }
                    }, 30000);
                  });
                }

                window.addEventListener("message", event => {
                  const data = event.data || {};
                  if (data.channel !== CHANNEL_RES) return;
                  const entry = pending.get(data.id);
                  if (!entry) return;
                  pending.delete(data.id);
                  if (data.error) {
                    entry.reject(new Error(String(data.error)));
                  } else {
                    entry.resolve(data.response);
                  }
                });

                document.addEventListener("click", event => {
                  const anchor = event.target && event.target.closest ? event.target.closest("a[href]") : null;
                  if (!anchor) return;
                  const href = anchor.getAttribute("href");
                  if (!href || href.startsWith("#")) return;
                  const target = (anchor.getAttribute("target") || "").toLowerCase();
                  if (target === "_blank") return;
                  let resolved;
                  try { resolved = new URL(href, location.href); } catch { return; }
                  if (resolved.origin !== LOCAL_ORIGIN) return;
                  event.preventDefault();
                  post("navigate", { url: resolved.toString(), method: "GET" });
                }, true);

                document.addEventListener("submit", event => {
                  const form = event.target;
                  if (!(form instanceof HTMLFormElement)) return;
                  const action = form.getAttribute("action") || location.href;
                  let resolved;
                  try { resolved = new URL(action, location.href); } catch { return; }
                  if (resolved.origin !== LOCAL_ORIGIN) return;
                  event.preventDefault();

                  const method = (form.getAttribute("method") || "GET").toUpperCase();
                  const formData = new FormData(form);
                  if (method === "GET") {
                    const params = new URLSearchParams();
                    for (const [k, v] of formData.entries()) {
                      if (typeof v === "string") params.append(k, v);
                    }
                    resolved.search = params.toString();
                    post("navigate", { url: resolved.toString(), method: "GET" });
                    return;
                  }

                  const enctype = (form.getAttribute("enctype") || "application/x-www-form-urlencoded").toLowerCase();
                  if (enctype.includes("multipart/form-data")) {
                    alert("PHP 模拟预览暂不支持 multipart/form-data 表单。");
                    return;
                  }

                  const params = new URLSearchParams();
                  for (const [k, v] of formData.entries()) {
                    if (typeof v === "string") params.append(k, v);
                  }
                  const bytes = new TextEncoder().encode(params.toString());
                  post("navigate", {
                    url: resolved.toString(),
                    method,
                    headers: { "content-type": "application/x-www-form-urlencoded;charset=UTF-8" },
                    bodyBase64: bytesToBase64(bytes)
                  });
                }, true);

                if (window.fetch) {
                  const nativeFetch = window.fetch.bind(window);
                  window.fetch = async (input, init = {}) => {
                    const request = new Request(input, init);
                    const url = new URL(request.url, location.href);
                    if (url.origin !== LOCAL_ORIGIN) {
                      return nativeFetch(input, init);
                    }

                    const headers = {};
                    request.headers.forEach((value, key) => { headers[key] = value; });

                    let bodyBase64 = null;
                    if (request.method !== "GET" && request.method !== "HEAD") {
                      const bytes = new Uint8Array(await request.arrayBuffer());
                      bodyBase64 = bytesToBase64(bytes);
                    }

                    const responsePayload = await rpc("fetch", {
                      url: url.toString(),
                      method: request.method,
                      headers,
                      bodyBase64
                    });

                    const responseBytes = base64ToBytes(responsePayload.bodyBase64 || "");
                    return new Response(responseBytes, {
                      status: responsePayload.status || 200,
                      statusText: responsePayload.statusText || "",
                      headers: responsePayload.headers || {}
                    });
                  };
                }
              })();
              `;
            }

            function looksLikeHTML(text) {
              const lowered = String(text || "").toLowerCase();
              return lowered.includes("<!doctype html") || lowered.includes("<html") || lowered.includes("<body");
            }

            (async () => {
              const payload = decodePayload();
              ensurePolyfills();

              const staticBlobMap = new Map();
              const preloadFiles = [];
              for (const file of payload.files || []) {
                const normalized = normalizePath(file.path);
                if (!normalized) continue;
                const bytes = base64ToBytes(file.base64 || "");
                const mime = file.mime || "application/octet-stream";
                const blobURL = URL.createObjectURL(new Blob([bytes], { type: mime }));
                staticBlobMap.set(normalized, blobURL);

                const slash = normalized.lastIndexOf("/");
                const parent = "/persist/project" + (slash >= 0 ? "/" + normalized.slice(0, slash) : "");
                const name = slash >= 0 ? normalized.slice(slash + 1) : normalized;
                preloadFiles.push({ parent, name, url: blobURL });
              }

              setStatus("PHP 引擎加载中…");
              const [{ PhpCgiWorker }, sqliteModule] = await Promise.all([
                import("https://cdn.jsdelivr.net/npm/php-cgi-wasm/PhpCgiWorker.mjs"),
                import("https://cdn.jsdelivr.net/npm/php-wasm-sqlite@0.0.9-x/index.mjs")
              ]);

              const php = new PhpCgiWorker({
                docroot: "/persist/project",
                prefix: "/",
                rewrite: path => path,
                files: preloadFiles,
                sharedLibs: [sqliteModule],
                staticCacheTime: 0,
                dynamicCacheTime: 0
              });

              let currentURL = new URL("/" + normalizePath(payload.entryPath || "index.php"), RUNTIME_ORIGIN).toString();

              function rewriteAssetReference(rawValue, pageURL) {
                if (!isLocalURL(rawValue)) return rawValue;
                let absolute;
                try { absolute = new URL(rawValue, pageURL); } catch { return rawValue; }
                if (absolute.origin !== RUNTIME_ORIGIN) return rawValue;
                const normalized = normalizePath(decodeURIComponent(absolute.pathname || ""));
                return staticBlobMap.get(normalized) || rawValue;
              }

              function renderRawResponse(status, contentType, bodyText) {
                const pretty = "[status " + status + "] " + (contentType || "text/plain") + "\\n\\n" + (bodyText || "");
                appFrame.srcdoc = "<!doctype html><html><body style=\\"margin:0;font:14px Menlo,monospace;background:#0b1020;color:#d7deff\\"><pre style=\\"white-space:pre-wrap;word-break:break-word;padding:16px\\">"
                  + escapeHTML(pretty)
                  + "</pre></body></html>";
              }

              function renderHTML(htmlText, requestURL) {
                const parsed = new DOMParser().parseFromString(htmlText, "text/html");
                if (!parsed.documentElement) {
                  renderRawResponse(200, "text/plain", htmlText);
                  return;
                }

                if (!parsed.head) {
                  const head = parsed.createElement("head");
                  parsed.documentElement.insertBefore(head, parsed.body || parsed.documentElement.firstChild);
                }

                const base = parsed.createElement("base");
                base.setAttribute("href", requestURL);
                parsed.head.prepend(base);

                const rewriteTargets = [
                  ["link[href]", "href"],
                  ["script[src]", "src"],
                  ["img[src]", "src"],
                  ["source[src]", "src"],
                  ["video[src]", "src"],
                  ["audio[src]", "src"]
                ];

                for (const [selector, attr] of rewriteTargets) {
                  parsed.querySelectorAll(selector).forEach(element => {
                    const raw = element.getAttribute(attr);
                    if (!raw) return;
                    element.setAttribute(attr, rewriteAssetReference(raw, requestURL));
                  });
                }

                const bridge = parsed.createElement("script");
                bridge.textContent = bridgeScriptText();
                if (parsed.body) {
                  parsed.body.appendChild(bridge);
                } else {
                  parsed.documentElement.appendChild(bridge);
                }

                appFrame.srcdoc = "<!doctype html>\\n" + parsed.documentElement.outerHTML;
              }

              async function executeRawRequest(url, init = {}) {
                const request = new Request(url, init);
                const response = await php.request(request);
                const headers = {};
                response.headers.forEach((value, key) => { headers[key.toLowerCase()] = value; });
                const bytes = new Uint8Array(await response.arrayBuffer());
                return {
                  status: response.status,
                  statusText: response.statusText || "",
                  headers,
                  bodyBase64: bytesToBase64(bytes)
                };
              }

              async function navigate(url, init = {}, redirectDepth = 0) {
                if (redirectDepth > 8) {
                  throw new Error("redirect loop");
                }

                const absoluteURL = new URL(url, currentURL).toString();
                const result = await executeRawRequest(absoluteURL, init);

                const locationHeader = result.headers.location;
                if (result.status >= 300 && result.status < 400 && locationHeader) {
                  const redirected = new URL(locationHeader, absoluteURL).toString();
                  return navigate(redirected, { method: "GET" }, redirectDepth + 1);
                }

                currentURL = absoluteURL;
                const bytes = base64ToBytes(result.bodyBase64 || "");
                const textBody = bytesToUtf8(bytes);
                const contentType = String(result.headers["content-type"] || "").toLowerCase();

                if (contentType.includes("text/html") || looksLikeHTML(textBody)) {
                  renderHTML(textBody, absoluteURL);
                  const skipped = payload.skippedFiles ? "（已跳过 " + payload.skippedFiles + " 个大文件）" : "";
                  setStatus("PHP + SQLite 模拟运行中 " + skipped);
                } else {
                  renderRawResponse(result.status, contentType, textBody);
                  setStatus("已返回非 HTML 响应");
                }
              }

              window.addEventListener("message", async event => {
                if (event.source !== appFrame.contentWindow) return;
                const data = event.data || {};
                if (data.channel !== CHANNEL_REQ) return;

                try {
                  if (data.type === "navigate") {
                    const payload = data.payload || {};
                    const init = requestInitFromPayload(payload);
                    await navigate(payload.url || currentURL, init, 0);
                    return;
                  }

                  if (data.type === "fetch") {
                    const payload = data.payload || {};
                    const init = requestInitFromPayload(payload);
                    const responsePayload = await executeRawRequest(payload.url || currentURL, init);
                    event.source.postMessage({
                      channel: CHANNEL_RES,
                      id: data.id,
                      response: responsePayload
                    }, "*");
                  }
                } catch (error) {
                  event.source.postMessage({
                    channel: CHANNEL_RES,
                    id: data.id,
                    error: String(error && error.message ? error.message : error)
                  }, "*");
                }
              });

              await navigate(currentURL, { method: "GET" }, 0);
            })().catch(error => {
              setStatus("PHP 运行时初始化失败: " + String(error && error.message ? error.message : error), true);
              appFrame.srcdoc = "<!doctype html><html><body style=\\"margin:0;background:#111;color:#fff;font:14px -apple-system;padding:16px\\"><pre style=\\"white-space:pre-wrap;word-break:break-word\\">"
                + escapeHTML(String(error && error.stack ? error.stack : error))
                + "</pre></body></html>";
            });
          </script>
        </body>
        </html>
        """
    }

    private static func relativePath(of fileURL: URL, from rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        if filePath == rootPath {
            return ""
        }
        guard filePath.hasPrefix(normalizedRoot) else { return nil }
        return String(filePath.dropFirst(normalizedRoot.count))
    }

    private static func normalizeRelativePath(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .joined(separator: "/")
    }

    private static func isHTMLPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".html") || lowered.hasSuffix(".htm")
    }

    private static func isPHPPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".php") || lowered.hasSuffix(".phtml")
    }

    private static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "php", "phtml":
            return "application/x-httpd-php"
        case "css":
            return "text/css; charset=utf-8"
        case "js", "mjs", "cjs":
            return "text/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "ico":
            return "image/x-icon"
        case "txt", "md":
            return "text/plain; charset=utf-8"
        default:
            return "application/octet-stream"
        }
    }
}
