"""Call the Supabase Management API: sbapi.py METHOD PATH [json]. Prints status and a short body."""
import sys, json, base64, secretstorage, urllib.request, urllib.error
bus = secretstorage.dbus_init(); tok = None
for col in secretstorage.get_all_collections(bus):
    for it in col.get_all_items():
        if 'supabase' in json.dumps(it.get_attributes()).lower() or 'supabase' in it.get_label().lower():
            s = it.get_secret().decode()
            if s.startswith('go-keyring-base64:'): s = base64.b64decode(s.split(':', 1)[1]).decode()
            if s.startswith('sbp_'): tok = s
assert tok
method, path = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode() if len(sys.argv) > 3 else (b'{}' if method != 'GET' else None)
req = urllib.request.Request('https://api.supabase.com' + path, data=data, method=method, headers={
    'Authorization': 'Bearer ' + tok, 'Content-Type': 'application/json',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'})
try:
    r = urllib.request.urlopen(req, timeout=90); print(r.status, r.read().decode()[:600])
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode()[:400])
