#!/usr/bin/env python3
"""Episode 13 assets: the connector secret record and the real ciphertext of its backup.

1. A connector set exactly in the shape McpService._pushRemote mirrors
   ({"connections": [McpConnection.toJson], "secrets": {id: McpSecrets.toJson}}),
   with random stand-in tokens (no real account, nothing that signs in anywhere).
2. That JSON -> EncryptionService.encrypt envelope (AES-256-GCM, {"v":"1","kv":1,
   nonce, ciphertext, mac}; random key, thrown away). That string is what the
   Supabase table cowork_mcp_connectors holds in its `ciphertext` column.
3. Logos: the app's bundled catalogue icons (assets/mcp_icons/<id>.png) are copied by
   episode.py. For the big hook tiles the brand favicons at 256 / 180 px were fetched
   once with a neutral agent string and are tracked in git as
   chuk-13-connectors/assets/img/brand/notion-256.png and linear-180.jpg; episode.py
   copies them from there into both formats (no fetch at build time).
Run once:  python3 _work/make_assets.py   -> _work/secrets.json
"""
import base64
import json
import os
import secrets
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
from chukvid import cipher  # noqa: E402

TOOLS = ["notion-search", "notion-fetch", "notion-create-pages", "notion-update-page",
         "notion-move-pages", "notion-duplicate-page", "notion-create-database",
         "notion-update-database", "notion-create-comment", "notion-get-comments",
         "notion-get-teams", "notion-get-users", "notion-get-user", "notion-get-self"]


def tok(n):
    return base64.urlsafe_b64encode(os.urandom(n)).decode().rstrip("=")


connection = {
    "id": "notion", "name": "Notion", "url": "https://mcp.notion.com/mcp",
    "description": "Search, read and write pages and databases.", "iconUrl": None,
    "tools": [{"name": t, "description": "", "inputSchema": {}} for t in TOOLS],
    "addedByHand": False, "auth": "oauth",
}
record = {
    "credentials": {"client_id": secrets.token_hex(8)},
    "tokens": {"access_token": tok(48), "refresh_token": tok(48),
               "expires_at": "2026-10-26T10:41:07.000Z", "scope": "default"},
    "issuer": "https://mcp.notion.com",
    "authorization_endpoint": "https://mcp.notion.com/authorize",
    "token_endpoint": "https://mcp.notion.com/token",
    "scope": "default",
}
payload = {"connections": [connection], "secrets": {"notion": record}}
plain = json.dumps(payload, separators=(",", ":"))
env, env_text = cipher.encrypt_bytes(plain.encode())   # same envelope as EncryptionService.encrypt

out = {
    "user_id": cipher.uid(),
    "updated_at": "2026-10-26 09:41:07+00",
    "record": record,
    "envelope": env,
    "envelope_text": env_text,
    "plain_chars": len(plain),
}
(HERE / "secrets.json").write_text(json.dumps(out, indent=1))
print("payload", len(plain), "chars -> envelope", len(env_text), "chars | ct", len(env["ciphertext"]))
