"""Drive agents-browser-mcp over stdio and print the fingerprint a site sees.

Run inside the browser image, with a page served on localhost:8765:

    docker run --rm --entrypoint sh -v "$PWD/agents/sandbox/docker:/probe:ro" \\
        agents-browser:latest -c "(cd /probe && python3 -m http.server 8765 &) ;
        sleep 1; python3 /probe/fingerprint-probe.py agents-browser-mcp"

Want: webdriver false, brands with \"Google Chrome\", tz = host time zone.
"""
import json, subprocess, sys

JS = """async () => { const gl=document.createElement('canvas').getContext('webgl');
const d=gl&&gl.getExtension('WEBGL_debug_renderer_info');
const h=navigator.userAgentData?await navigator.userAgentData.getHighEntropyValues(['fullVersionList']):null;
return JSON.stringify({webdriver:navigator.webdriver, ua:navigator.userAgent,
brands:h&&h.fullVersionList.map(b=>b.brand), languages:navigator.languages,
tz:Intl.DateTimeFormat().resolvedOptions().timeZone, offset:new Date().getTimezoneOffset(),
gl:d?gl.getParameter(d.UNMASKED_RENDERER_WEBGL):null,
pw:Object.keys(window).filter(k=>/playwright|__pw|cdc_/i.test(k))}); }"""

p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def call(i, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("id") == i:
            return m
call(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "1"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
call(2, "tools/call", {"name": "browser_navigate", "arguments": {"url": "http://localhost:8765/"}})
r = call(3, "tools/call", {"name": "browser_evaluate", "arguments": {"function": JS}})
print("\n".join(c.get("text", "") for c in r["result"]["content"])[:1500])
p.kill()
