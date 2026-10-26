# REVIEW: chuk-11-local-search

Outputs: `marketing/out/11-local-search.mp4` (1920x1080) and
`marketing/out/11-local-search-vertical.mp4` (1080x1920), 45.0 s each, 30 fps, H.264 + AAC,
`--quality high --gpu -w 4`.

## Build

```
python3 _work/make_assets.py   # real widget renders (flutter test) + fidelity sheets
python3 _work/episode.py       # both projects (this folder and ../chuk-11-local-search-vertical)
```
Edit `_work/episode.py` / `_work/sidebar.py`, never `compositions/`.

## Decisions

- Sidebar rebuilt in `_work/sidebar.py` from sidebar_chrome.dart / sidebar_desktop.dart /
  sidebar_mobile.dart, checked against the REAL widgets rendered in a widget test
  (`_work/fidelity_test/real_sidebar_test.dart`, Clawed dark theme, seeded
  `ChatStorageState`, `.env` never read). Sheets: `_work/fidelity/{desktop,mobile}-{idle,search}.jpg`,
  side by side `cmp-*.png`. Theme tokens dumped to `real-tokens.json`.
- The test font is the variable Ubuntu TTF; Flutter draws its w500 chat titles wider than CSS
  does, so the title uses letter-spacing 0.65 to match the real truncation points.
- Mobile panel at 360 wide (not 412) so the date lines reach 34 px inside 1080 px.
- Workspaces off (production default, `kFeatureWorkspaces` is false; the desktop widget test
  also passes `showWorkspacesButton: false`): nav block is New chat, Media, Search (desktop) and
  Media, Search (phone; New chat is the round button in the head bar).
- Search typing 5.5 keys/s instead of the series' 18 chars/s so every filter step is visible.
  The per-key list states use the app's rule (case-insensitive contains on the title;
  the fictional chats have no message text).
- The request counter is a visual device, labelled "Requests while you search", and only
  counts what is true: the desktop filter is synchronous in memory, the phone filter runs in
  a background isolate; neither sends a request. "Not one request." is scoped to this sidebar
  search filter (the counter title says "while you search"); it is not a claim that the app
  sends nothing at all, and the search_chats tool is out of scope.
- Code shown per format matches the sidebar on screen (desktop vs phone). The search_chats
  tool (SQLite chat_cache.db) is not shown, because its results go to the model.
- No new music cuts beyond the beat grid, no sound effects.

## Checks

- `npx hyperframes check`: ok in both. Warnings kept: line_unread on the per-key list states
  (intended), type floor counted in app px before zoom (same as 08/09), contrast flags on the
  hook tiles where the mask fades them out.
- Snapshot with browser GPU showed tile glitches in 9:16 s02 once; the render was clean
  (frames decoded from the MP4).
- Full-size frames in `_work/final/` and `../chuk-11-local-search-vertical/_work/final/`.

## Weakest shot

s06: the device outline is a simple line drawing; it reads, but it is the least "real" shot.
