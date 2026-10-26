# REVIEW: chuk-13-connectors

Outputs: `marketing/out/13-connectors.mp4` (1920x1080) and `marketing/out/13-connectors-vertical.mp4`
(1080x1920), 45.0 s each, 30 fps, H.264 + AAC, `--quality high --gpu -w 4` under the render lock.

## Build

```
python3 _work/make_assets.py   # once: secrets.json (stand-in record + real ciphertext of the backup)
flutter test marketing/videos/chuk-13-connectors/_work/fidelity_test/real_widgets_test.dart   # repo root
python3 _work/episode.py       # both projects
python3 _work/fidelity.py      # sheets in _work/fidelity/*.jpg
```
Edit `_work/episode.py`, never `compositions/`.

## Decisions

- Connectors page and detail page: rebuilt from the REAL widgets rendered in a widget test
  (`McpConnectorsPage`, `McpConnectorDetailPage`, in-memory store, mock HTTP, no Supabase, no
  .env). The test also dumps every text's box and style to `real-*.json`; the rebuild reads its
  subtitle line counts and detail-page tops from there. Logos are the app's bundled
  `assets/mcp_icons/*.png`. Real page order; GitHub (first-party, Developer section) is far below
  the frame and never drawn.
- Test fonts: the app leaves ThemeData.fontFamily unset (system font = Ubuntu on the desktop);
  the test puts Ubuntu on the theme styles that have no family, else they draw as boxes.
- UI zoom 2.5 / 2.85 so 12 px app text is 30 / 34 px. The window is taller than the frame and the
  camera pans; the header leaves the frame on the pan.
- Consent screen: neutral, not Notion's page. It does not name the client: the app registers as
  `client_name: "Agents"` (`McpOAuth.clientName`) and the loopback page says "... go back to
  Agents", which would confuse a Chuk Chat viewer. The video shows only "Connected. You can close
  this tab." (first sentence of the real page).
- Address bar: the real authorize parameters (response_type, client_id, redirect_uri on
  localhost:<port>/mcp/callback, S256, state, resource); authorization endpoint checked live
  (mcp.notion.com/.well-known/oauth-authorization-server, neutral agent string).
- Secure storage card: not an app screen; McpSecrets.toJson shape, tokens masked. Client id is a
  random stand-in. Backup ciphertext: the McpService._pushRemote payload shape with stand-in
  tokens, sealed like EncryptionService.encrypt (AES-256-GCM, v "1", key thrown away).
- Hook tiles use the 256/180 px brand favicons (Notion, Linear) and the bundled Todoist icon:
  the bundled Linear PNG is only 48 px.
- "14 tools": the 14 tool names of Notion's hosted MCP server as listed in the widget test.

## Checks

- `npx hyperframes check`: ok, 0 errors in both. Warnings kept: `text_below_floor` on app text
  (the check reads the 12 px CSS size before `zoom`; rendered it is 30 / 34 px), read-time
  warnings on UI text and the URL, one duplicate image (Notion logo in list + detail).
- Full-size frames of both MP4s in `_work/final/` and `../chuk-13-connectors-vertical/_work/final/`.

## Weakest shot

s02 cross-fade (list to detail, ~0.3 s) overlaps two dark pages; s04 is short (2.2 s).
