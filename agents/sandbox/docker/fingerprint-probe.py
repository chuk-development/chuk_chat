"""Drive agents-browser-mcp over stdio and print the fingerprint a site sees.

It serves its own page on 127.0.0.1:8765, records the request headers of
that page, and evaluates a JS probe in it through the MCP. Run it inside the
browser image (add the GPU flags the sandbox uses, see docker.py,
``host_gpu_run_args``):

    docker run --rm --gpus all,capabilities=graphics --entrypoint sh -e TZ=Europe/Berlin \\
        -e AGENTS_BROWSER_LOCALE=de-DE \\
        -v "$PWD/agents/sandbox/docker/fingerprint-probe.py:/probe.py:ro" \\
        agents-browser:latest -c "python3 /probe.py"

Extra arguments replace the launcher command (default: agents-browser-mcp).

Want (a normal German desktop Chrome on Linux):
  webdriver false, brands with "Google Chrome", tz = host time zone,
  Accept-Language "de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7",
  languages ["de-DE","de","en-US","en"], a WebGL renderer that names a real
  GPU (not SwiftShader / llvmpipe), outer window <= screen, avail < screen,
  media devices listed (audioinput, videoinput, audiooutput), cdpLeak false.
"""
import http.server
import json
import subprocess
import sys
import threading

HEADERS = {}


class _Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server API
        HEADERS[self.path] = dict(self.headers)
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.end_headers()
        self.wfile.write(b"<!doctype html><html><body>probe</body></html>")

    def log_message(self, *_):
        pass


JS = """async () => {
let leak = false; const e = new Error();
Object.defineProperty(e, 'stack', { get() { leak = true; return ''; } });
console.debug(e);
const c = document.createElement('canvas'); const gl = c.getContext('webgl');
const d = gl && gl.getExtension('WEBGL_debug_renderer_info');
const h = navigator.userAgentData
  ? await navigator.userAgentData.getHighEntropyValues(['fullVersionList', 'platformVersion'])
  : null;
const media = await navigator.mediaDevices.enumerateDevices();
return JSON.stringify({
  webdriver: navigator.webdriver, ua: navigator.userAgent,
  brands: h && h.fullVersionList.map(b => b.brand), platformVersion: h && h.platformVersion,
  languages: navigator.languages, language: navigator.language,
  tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
  locale: Intl.DateTimeFormat().resolvedOptions().locale,
  glVendor: d ? gl.getParameter(d.UNMASKED_VENDOR_WEBGL) : null,
  glRenderer: d ? gl.getParameter(d.UNMASKED_RENDERER_WEBGL) : null,
  gl2Renderer: (() => { const g2 = document.createElement('canvas').getContext('webgl2');
    const d2 = g2 && g2.getExtension('WEBGL_debug_renderer_info');
    return d2 ? g2.getParameter(d2.UNMASKED_RENDERER_WEBGL) : null; })(),
  glParams: gl ? [gl.getParameter(gl.MAX_TEXTURE_SIZE), gl.getParameter(gl.MAX_RENDERBUFFER_SIZE),
    Array.from(gl.getParameter(gl.MAX_VIEWPORT_DIMS)), gl.getParameter(gl.MAX_CUBE_MAP_TEXTURE_SIZE),
    gl.getSupportedExtensions().length] : null,
  glNative: gl ? String(WebGLRenderingContext.prototype.getParameter) : null,
  screen: [screen.width, screen.height, screen.availWidth, screen.availHeight,
           screen.availLeft, screen.availTop, screen.colorDepth, devicePixelRatio],
  window: [outerWidth, outerHeight, innerWidth, innerHeight, screenX, screenY],
  media: media.map(m => m.kind + (m.label ? ':' + m.label : '')),
  hc: navigator.hardwareConcurrency, dm: navigator.deviceMemory,
  plugins: navigator.plugins.length, pdf: navigator.pdfViewerEnabled,
  cdpLeak: leak,
  chromeKeys: Object.keys(window.chrome || {}),
  notifications: [Notification.permission,
                  (await navigator.permissions.query({name: 'notifications'})).state],
  camera: (await navigator.permissions.query({name: 'camera'})).state,
  voices: speechSynthesis.getVoices().length,
  audio: (() => { try { const a = new AudioContext();
    return [a.sampleRate, a.baseLatency, a.destination.maxChannelCount]; }
    catch (err) { return String(err); } })(),
  webgpu: navigator.gpu ? await navigator.gpu.requestAdapter()
    .then(a => a && [a.info.vendor, a.info.architecture]).catch(err => String(err)) : null,
  pw: Object.keys(window).filter(k => /playwright|__pw|cdc_/i.test(k)),
});
}"""


def main() -> None:
    server = http.server.HTTPServer(("127.0.0.1", 8765), _Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    command = sys.argv[1:] or ["agents-browser-mcp"]
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def send(message):
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", **message}) + "\n")
        proc.stdin.flush()

    def call(i, method, params):
        send({"id": i, "method": method, "params": params})
        while True:
            line = proc.stdout.readline()
            if not line:
                raise SystemExit("the MCP server exited")
            reply = json.loads(line)
            if reply.get("id") == i:
                return reply

    try:
        call(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                               "clientInfo": {"name": "probe", "version": "1"}})
        send({"method": "notifications/initialized"})
        call(2, "tools/call", {"name": "browser_navigate",
                               "arguments": {"url": "http://127.0.0.1:8765/"}})
        reply = call(3, "tools/call", {"name": "browser_evaluate", "arguments": {"function": JS}})
        text = "\n".join(c.get("text", "") for c in reply["result"]["content"])
        # The tool answers in Markdown; the JSON string is the first line after "### Result".
        raw = text.split("### Result", 1)[-1].strip().splitlines()[0]
        try:
            result = json.loads(json.loads(raw))
        except ValueError:
            # An error from the page or the tool: show it as it came.
            print(text)
            raise SystemExit(1) from None
        page = HEADERS.get("/", {})
        result["acceptLanguage"] = page.get("Accept-Language")
        result["secChUa"] = page.get("sec-ch-ua")
        print(json.dumps(result, indent=1, ensure_ascii=False))
    finally:
        proc.kill()
        server.shutdown()


if __name__ == "__main__":
    main()
