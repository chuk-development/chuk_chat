import sys, json, base64, secretstorage, urllib.request
bus = secretstorage.dbus_init()
tok = None
for col in secretstorage.get_all_collections(bus):
    for it in col.get_all_items():
        a = it.get_attributes()
        if 'supabase' in json.dumps(a).lower() or 'supabase' in it.get_label().lower():
            s = it.get_secret().decode()
            if s.startswith('go-keyring-base64:'):
                s = base64.b64decode(s.split(':',1)[1]).decode()
            if s.startswith('sbp_'): tok = s
assert tok, 'no token'
req = urllib.request.Request('https://api.supabase.com/v1/projects/xooposctxswumvgtyqlg/database/query',
    data=json.dumps({'query': sys.stdin.read()}).encode(),
    headers={'Authorization': 'Bearer '+tok, 'Content-Type': 'application/json',
             'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'})
for row in json.loads(urllib.request.urlopen(req, timeout=60).read()):
    print(' | '.join(str(v)[:150] for v in row.values()))
