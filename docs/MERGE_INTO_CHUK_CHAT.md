# Merging Agents into chuk_chat

Agents and chuk_chat are two working trees of one product. They share no commit.
Agents took the chat UI as a file copy (`scripts/import_chat_ui.sh`), so the same
UI is now edited in two places. This file records what a real merge costs, in
measured numbers, and gives the command sequence that performs it.

**Goal state.** One repository: `chuk-development/chuk_chat`. The Flutter app at
the repository root, Dart package `chuk_chat`. The Agents features behind the
`FEATURE_AGENTS` dart-define that `scripts/build_apk.sh` already sets. The Python
subsystems as plain top-level directories. `scripts/import_chat_ui.sh` deleted,
because there is nothing left to import.

**Measured on 2026-09-13** in a throwaway clone at `/home/user/git/cowork-graft`.
Nothing in `/home/user/git/cowork` and nothing in `/home/user/git/chuk_chat` was
changed.

| Side | Ref | Commits | Tracked files |
|---|---|---:|---:|
| Agents | `agents` @ `869748c`, root `593fe9f` (2026-08-12 … 2026-09-13) | 306 | 1330 |
| chuk_chat | `master` @ `a249a54` | 1373 | 1580 |
| Pinned baseline | `d31526a` (`docs/CHAT_UI_IMPORT.md`) | — | 1338 |

`d31526a` is 57 commits behind `master`. Note that
`tools/chat_ui_manifest.txt` names a different, **newer** pin in its header
(`4d2ff4a`, which has `d31526a` as an ancestor). This runbook uses `d31526a`,
the pin in `docs/CHAT_UI_IMPORT.md`. Reconcile the two headers before the merge.

## 1. The graft is a lie. Do not use it

`git replace --graft 593fe9f d31526a` makes the Agents root commit a child of the
upstream baseline. Because the graft computes the root commit's diff against the
full baseline tree, the root commit stops meaning "Agents starts here" and starts
meaning "delete almost all of chuk_chat".

Measured on the grafted root commit:

```
1411 files changed, 8054 insertions(+), 274016 deletions(-)
  1282 files deleted   74 added   2 modified   53 renames detected
```

The deletions are the whole product: `vendor/` (437), `lib/` (332), `test/` (114),
`assets/` (114), `android/` (40), `ios/` (39), `macos/` (31), `docs/` (26),
`supabase/` (24), `migrations/` (24), `windows/` (18), `web/` (8), `linux/` (5).
Exactly **one** file survives the graft unchanged
(`docs/AGENTS_AGENT_PLATFORM_PLAN.md`). Rename detection adds noise rather than
sense: it pairs `vendor/markdraw/android/**` with `app/android/**` and pairs
`.codex` with `common/chuk_agents_crypto/src/chuk_agents_crypto/py.typed`.

The damage is not cosmetic. With the graft in place, `git merge upstream/master`
uses `d31526a` as the real merge base, reads those 1282 deletions as a deliberate
Agents decision, and applies them:

| Result of merging `upstream/master` with the graft active | Count |
|---|---:|
| Upstream files staged for **deletion**, silently, no conflict | **1067** |
| Conflicts | 201 |
| … of type `modify/delete` (upstream changed a file Agents "deleted") | 107 |
| … of type `content` | 62 |
| … of type `file location` | 30 |
| … `rename/delete`, `distinct types`, `add/add` | 1 each |

A merge that throws away `android/`, `ios/`, `macos/`, `web/`, `vendor/` and two
thirds of `lib/` is not a merge. **Recommendation: do not graft.** Use the
sequence in section 2 instead, where the merge base is the empty tree and no file
is ever deleted.

## 2. Path and package alignment with `git filter-repo`

The Agents Flutter app lives under `app/`. `app/` holds `.env.example`,
`.gitignore`, `.metadata`, `README.md`, `analysis_options.yaml`, `android/`,
`assets/`, `lib/`, `linux/`, `pubspec.yaml`, `test/`, `third_party/`, `tool/` —
875 tracked files. Moving all of it to the repository root collides with exactly
**two** paths that Agents already has at the root: `.gitignore` and `README.md`.
Both are handled by renaming the Agents root copies out of the way first, so the
Flutter `.gitignore` and the Flutter `README.md` land at the root where
chuk_chat's own copies are, and merge against their counterparts.

The rewrite is clean and fast:

| Measure | Result |
|---|---|
| Wall time | **1.8 s** (1.33 s rewrite + repack) |
| Commits in, commits out | 306 → **306**, none pruned, none emptied |
| `package:chuk_chat/` occurrences left | **0** |
| Files carrying `package:chuk_chat/` at HEAD | 412 |
| `name: agents` in `pubspec.yaml` | rewritten to `name: chuk_chat` in every commit |
| `app/` paths left anywhere in history | 0 |

`git filter-repo` rewrites paths, not file contents. 51 files still hold the
literal string `app/`. All but six are prose (`docs/**`, `CLAUDE.md`,
`.beads/interactions.jsonl`). The six that break something are listed in
section 6.

## 3. What the merge costs

With the paths aligned, merge `upstream/master` and `agents` with **no common
ancestor** (`--allow-unrelated-histories`, merge base = the empty tree). Git then
keeps every file from both sides and raises a conflict only where both sides
carry the same path with different content. No file is deleted:

```
208 unmerged paths   —   205 add/add, 1 file/directory, 1 distinct types
0   upstream files deleted
```

Every colliding path is then resolved per file with a three-way merge whose base
is the file at `d31526a`. That turns 410 collisions into five buckets:

| Bucket | Files | Resolution |
|---|---:|---|
| Byte-identical on both sides | **204** | git resolves it, no action |
| Pure upstream drift (Agents side equals `d31526a`) | **16** | take upstream |
| Pure Agents divergence (upstream side equals `d31526a`) | **83** | take Agents |
| Both edited, three-way merge succeeds | **29** | take the merged text |
| Both edited, three-way merge conflicts | **78** | by hand |
| **Total colliding** | **410** | |

And the rest of the two trees:

| Bucket | Files |
|---|---:|
| Agents-only, pure addition | **920** (317 of them Python) |
| Upstream-only, untouched by the merge | **1170** |
| Union after the merge | **2500** |

So the true cost is **78 files to resolve by hand**, plus two structural
oddities (section 5). Of the 78, 75 are genuine both-sides edits and 3 are
add/add pairs with no ancestor at `d31526a` (upstream and Agents each invented a
file at the same path). **Zero** conflicts come from pure upstream drift — drift
alone always merges clean, because the Agents side still equals the baseline.
There are no binary conflicts: the five `ic_launcher.png` files differ, but only
Agents changed them.

The 78 files hold **301** conflict hunks. `chat_ui_mobile.dart` alone holds 61 of
them (20 %); the other 77 files hold 240. 33 files have a single hunk and 13 have
two, so half the list is a few minutes of work each.

### The ten worst files

| hunks | upstream +/- vs `d31526a` | Agents +/- vs `d31526a` | file |
|---:|---:|---:|---|
| 61 | 575/1355 | 700/3158 | `lib/platform_specific/chat/chat_ui_mobile.dart` |
| 19 | 1044/515 | 112/75 | `lib/widgets/sidebar/sidebar_chrome.dart` |
| 12 | 36/34 | 199/205 | `lib/pages/about_page.dart` |
| 11 | 12/72 | 85/162 | `lib/l10n/strings_fr.dart` |
| 11 | 45/65 | 397/305 | `lib/model_selector_page.dart` |
| 11 | 26/70 | 233/212 | `lib/pages/account_settings_page.dart` |
| 11 | 482/1034 | 410/350 | `lib/platform_specific/chat/chat_ui_desktop.dart` |
| 7 | 45/186 | 90/613 | `lib/pages/settings_page.dart` |
| 7 | 18/11 | 162/424 | `lib/pages/skills_settings_page.dart` |
| 6 | 15/33 | 150/526 | `lib/pages/login_page.dart` |

### Every conflicting file

| hunks | kind | upstream +/- vs base | Agents +/- vs base | file |
|---:|---|---:|---:|---|
| 61 | both edited | 575/1355 | 700/3158 | `lib/platform_specific/chat/chat_ui_mobile.dart` |
| 19 | both edited | 1044/515 | 112/75 | `lib/widgets/sidebar/sidebar_chrome.dart` |
| 12 | both edited | 36/34 | 199/205 | `lib/pages/about_page.dart` |
| 11 | both edited | 12/72 | 85/162 | `lib/l10n/strings_fr.dart` |
| 11 | both edited | 45/65 | 397/305 | `lib/model_selector_page.dart` |
| 11 | both edited | 26/70 | 233/212 | `lib/pages/account_settings_page.dart` |
| 11 | both edited | 482/1034 | 410/350 | `lib/platform_specific/chat/chat_ui_desktop.dart` |
| 7 | both edited | 45/186 | 90/613 | `lib/pages/settings_page.dart` |
| 7 | both edited | 18/11 | 162/424 | `lib/pages/skills_settings_page.dart` |
| 6 | both edited | 15/33 | 150/526 | `lib/pages/login_page.dart` |
| 6 | both edited | 8/20 | 395/157 | `lib/widgets/sandbox_artifact_block.dart` |
| 6 | both edited | 28/34 | 176/124 | `pubspec.yaml` |
| 5 | both edited | 16/27 | 117/340 | `lib/pages/customization_page.dart` |
| 5 | both edited | 17/20 | 107/169 | `lib/pages/desktop_settings_modal.dart` |
| 5 | both edited | 19/7 | 27/14 | `lib/pages/recover_chats_page.dart` |
| 5 | both edited | 71/4 | 788/488 | `lib/services/mcp/mcp_service.dart` |
| 4 | both edited | 24/36 | 42/42 | `lib/pages/fullscreen_map_page.dart` |
| 4 | both edited | 12/11 | 112/93 | `lib/pages/theme_page.dart` |
| 4 | both edited | 231/282 | 56/35 | `lib/platform_specific/chat/desktop_send_logic.dart` |
| 4 | both edited | 13/26 | 51/43 | `lib/widgets/attachment_preview_bar.dart` |
| 4 | both edited | 32/29 | 18/5 | `lib/widgets/nice_snackbar.dart` |
| 4 | both edited | 18/23 | 9/662 | `lib/widgets/workspace_file_viewer.dart` |
| 3 | both edited | 12/64 | 41/32 | `lib/l10n/strings_es.dart` |
| 3 | both edited | 12/64 | 18/31 | `lib/l10n/strings_pt.dart` |
| 3 | both edited | 116/524 | 7/1148 | `lib/pages/workspace_management_page.dart` |
| 3 | both edited | 100/119 | 5/5 | `lib/platform_specific/chat/widgets/fullscreen_composer.dart` |
| 3 | both edited | 151/139 | 119/112 | `lib/platform_specific/chat/widgets/mobile_chat_widgets.dart` |
| 3 | both edited | 2/13 | 31/1832 | `lib/services/artifact_storage_service.dart` |
| 3 | both edited | 25/72 | 17/899 | `lib/services/title_generation_service.dart` |
| 3 | both edited | 9/8 | 61/65 | `lib/widgets/image_viewer.dart` |
| 3 | both edited | 30/87 | 149/150 | `lib/widgets/model_selection_dropdown.dart` |
| 3 | both edited | 36/167 | 6/826 | `lib/widgets/workspace_panel.dart` |
| 2 | both edited | 102/0 | 17/61 | `android/app/src/main/AndroidManifest.xml` |
| 2 | both edited | 63/16 | 156/408 | `lib/main.dart` |
| 2 | both edited | 7/5 | 66/30 | `lib/pages/coming_soon_page.dart` |
| 2 | both edited | 15/27 | 8/681 | `lib/pages/pricing_page.dart` |
| 2 | both edited | 4/3 | 9/1329 | `lib/pages/usage_details_page.dart` |
| 2 | both edited | 1/29 | 18/433 | `lib/services/file_conversion_service.dart` |
| 2 | both edited | 1/22 | 82/281 | `lib/services/image_storage_service.dart` |
| 2 | both edited | 1/42 | 23/1067 | `lib/services/workspace_storage_service.dart` |
| 2 | both edited | 80/27 | 74/42 | `lib/widgets/anchored_menu.dart` |
| 2 | both edited | 7/10 | 29/31 | `lib/widgets/document_viewer.dart` |
| 2 | both edited | 9/19 | 16/6 | `lib/widgets/route_map_widget.dart` |
| 2 | both edited | 8/7 | 6/265 | `lib/widgets/workspace_selection_dropdown.dart` |
| 2 | both edited | 3/2 | 141/192 | `test/pages/skills_settings_page_test.dart` |
| 1 | both edited | 26/0 | 241/13 | `.beads/interactions.jsonl` |
| 1 | both edited | 17/0 | 3/92 | `.gitignore` |
| 1 | both edited | 51/0 | 1/309 | `AGENTS.md` |
| 1 | both edited | 87/37 | 99/449 | `CLAUDE.md` |
| 1 | both edited | 12/0 | 11/185 | `README.md` |
| 1 | both edited | 4/1 | 39/72 | `android/app/build.gradle.kts` |
| 1 | both edited | 101/3 | 27/3 | `lib/platform_specific/chat/chat_scroll_mixin.dart` |
| 1 | both edited | 181/19 | 64/10 | `lib/platform_specific/chat/chat_ui_helpers.dart` |
| 1 | both edited | 9/76 | 4/4 | `lib/platform_specific/chat/handlers/file_attachment_handler.dart` |
| 1 | both edited | 2/28 | 3/6 | `lib/services/chat_preload_service.dart` |
| 1 | both edited | 15/6 | 17/7 | `lib/services/chat_storage_sidebar.dart` |
| 1 | both edited | 0/1 | 116/163 | `lib/services/offline_retry_manager.dart` |
| 1 | both edited | 118/596 | 11/2 | `lib/services/streaming_manager_io.dart` |
| 1 | both edited | 6/402 | 6/1 | `lib/services/streaming_manager_stub.dart` |
| 1 | both edited | 0/2 | 11/228 | `lib/services/streaming_transcription_service.dart` |
| 1 | both edited | 7/31 | 13/0 | `lib/services/supabase_service.dart` |
| 1 | both edited | 0/22 | 22/390 | `lib/services/workspace_message_service.dart` |
| 1 | both edited | 2/17 | 12/936 | `lib/tool_handlers/notes_tools.dart` |
| 1 | both edited | 10/9 | 5/3 | `lib/widgets/accent_icon_button.dart` |
| 1 | both edited | 2/1 | 357/74 | `lib/widgets/chuk_table.dart` |
| 1 | both edited | 28/1 | 106/79 | `lib/widgets/credit_display.dart` |
| 1 | add/add (no ancestor) | — | — | `lib/widgets/menu_tile_group.dart` |
| 1 | both edited | 6/6 | 9/7 | `lib/widgets/message_bubble/cards.dart` |
| 1 | both edited | 6/6 | 49/91 | `lib/widgets/message_bubble/chrome.dart` |
| 1 | both edited | 11/5 | 760/90 | `lib/widgets/message_bubble/layout.dart` |
| 1 | both edited | 9/32 | 16/11 | `lib/widgets/message_bubble/rich_blocks.dart` |
| 1 | both edited | 26/9 | 9/5 | `lib/widgets/message_bubble/tools.dart` |
| 1 | both edited | 2/1 | 11/3 | `lib/widgets/message_bubble/web_search_sources.dart` |
| 1 | both edited | 6/3 | 9/15 | `lib/widgets/per_model_system_prompt_sheet.dart` |
| 1 | both edited | 23/1 | 12/1 | `lib/widgets/settings_list_view.dart` |
| 1 | both edited | 7/6 | 11/21 | `lib/widgets/weather_widget.dart` |
| 1 | add/add (no ancestor) | — | — | `test/support/kv_cache_test_env.dart` |
| 1 | add/add (no ancestor) | — | — | `test/widgets/composer_recording_row_test.dart` |

### Files to take from upstream verbatim (pure drift, 16)

```
android/app/src/main/res/values-night/styles.xml
android/app/src/main/res/values/styles.xml
lib/constants/file_constants.dart
lib/env_loader.dart
lib/models/stored_chat.dart
lib/platform_specific/chat/handlers/chat_persistence_handler.dart
lib/platform_specific/chat/handlers/desktop_file_handler.dart
lib/services/app_lifecycle_service.dart
lib/services/chat_history_builder.dart
lib/services/chat_runtime_registry.dart
lib/services/chat_storage_sync.dart
lib/services/developer_options_service.dart
lib/services/model_capabilities_service.dart
lib/services/tour_key_registry.dart
lib/services/user_preferences_service.dart
lib/utils/certificate_pinning.dart
```

## 4. What moved or vanished upstream since `d31526a`

`tools/chat_ui_manifest.txt` has **133** entries. Against `upstream/master`:
**35** are still byte-identical after the package rewrite, **88** have diverged,
and **10** do not resolve. The 10 are not what the manifest's error message
suggests.

**Nine of the ten are typos in the manifest, not upstream moves.** The manifest
header says each line is relative to `<chuk_chat>/lib`, but these nine lines carry
a second `lib/` prefix, so the importer looks for `lib/lib/services/…`, which
never existed — not upstream today, and not at `d31526a` either:

```
lib/services/user_preferences_service.dart
lib/services/api_status_service.dart
lib/services/network_status_service.dart
lib/services/supabase_service.dart
lib/services/tour_key_registry.dart
lib/services/api_config_service.dart
lib/utils/theme_extensions.dart
lib/widgets/anchored_menu.dart
lib/widgets/expressive_settings.dart
```

All nine files exist upstream and in Agents at their correct paths, and all nine
are covered by the buckets in section 3. **For the merge they mean nothing.**
Strip the duplicated prefix when the manifest is retired.

**One is a real upstream removal.** `platform_specific/chat/widgets/desktop_chat_widgets.dart`
exists at `d31526a` and in Agents, and upstream deleted it in `52eb2840`
("fix(ui): the header inset is right from both sides of the Scaffold …"). Upstream
replaced it with `lib/platform_specific/chat/widgets/chat_message_list_item.dart`,
which both `chat_ui_desktop.dart` and `chat_ui_mobile.dart` now import.

What that means for the merge: an unrelated-histories merge **keeps** the Agents
file, because nothing deletes it. So the merged tree holds both
`desktop_chat_widgets.dart` (dead, Agents's, imported by nobody after the
`chat_ui_*.dart` conflicts are resolved towards upstream's structure) and
`chat_message_list_item.dart` (live, upstream's). Resolve
`chat_ui_desktop.dart` / `chat_ui_mobile.dart` towards upstream's list-item
widget and then `git rm lib/platform_specific/chat/widgets/desktop_chat_widgets.dart`.
This is a piece of the 61-hunk and 11-hunk conflicts in those two screens, not a
separate task.

Upstream also added 37 new files under `lib/` since `d31526a` — `lib/assistant/*`
(9 files), `lib/widgets/icons/*`, `lib/widgets/settings_kit.dart`,
`lib/utils/json_helpers.dart` and so on. All of them are pure additions and carry
no cost.

## 5. The Python side: a pure addition

Zero collisions. Not one path under the six subsystem directories exists in
chuk_chat master.

| Directory | Agents files | chuk_chat master files | Collisions |
|---|---:|---:|---:|
| `agent/` | 100 | 0 | 0 |
| `executor/` | 59 | 0 | 0 |
| `host/` | 57 | 0 | 0 |
| `manager/` | 33 | 0 | 0 |
| `sandbox/` | 27 | 0 | 0 |
| `common/` | 41 | 0 | 0 |
| **Total** | **317** | **0** | **0** |

`extension/` (21), `skills/` (7) and `tools/` (7) are also pure additions.
`scripts/` (7 Agents files, 12 upstream files) shares the directory but no
filename.

### The structural oddities

Two paths differ in *type*, not in content. Git names them `file/directory` and
`distinct types` and parks the loser under a `~HEAD` suffix.

| Path | chuk_chat master | Agents | Take |
|---|---|---|---|
| `.codex` | empty regular file | directory (`config.toml`, `hooks.json`) | Agents's directory |
| `AGENTS.md` | regular file | symlink → `CLAUDE.md` | decide once; the two `AGENTS.md` bodies also differ |

Delete the `.codex~HEAD` and `AGENTS.md~HEAD` leftovers after resolving.

### App identity: the merge gets this wrong unless you override it

Six identity-bearing files fall in the "pure Agents divergence → take Agents"
bucket. Taking Agents's version there would rename and re-icon the **shipped**
chuk_chat app. Android would change `applicationId` from `dev.chuk.chat` to
`dev.chuk.cowork`, which ends update continuity for every installed copy on the
Play Store. Force these to upstream regardless of bucket:

| File | Bucket the rule would pick | What breaks |
|---|---|---|
| `linux/CMakeLists.txt` | take Agents | `BINARY_NAME "agents"`, `APPLICATION_ID dev.chuk.cowork` |
| `linux/runner/my_application.cc` | take Agents | window title |
| `android/app/build.gradle.kts` | conflict (1 hunk) | `namespace` / `applicationId` |
| `android/app/src/main/AndroidManifest.xml` | conflict (2 hunks) | `android:label` |
| `android/app/src/main/res/mipmap-*/ic_launcher.png` (5) | take Agents | launcher icon |
| `.metadata` | take Agents | Flutter project id |

There is also exactly one stale duplicate:
`android/app/src/main/kotlin/dev/chuk/cowork/MainActivity.kt` is Agents-only and
sits next to upstream's `android/app/src/main/kotlin/dev/chuk/chat/MainActivity.kt`.
Delete the Agents one; upstream's package is the one the manifest names.

## 6. The sequence

Every stage before stage 7 lives in a scratch clone. Nothing touches
`/home/user/git/cowork`, `/home/user/git/chuk_chat` or any remote.

### Stage 0 — scratch clone (reversible: `rm -rf`)

```bash
rm -rf ~/git/chuk_chat-merge
git clone --no-hardlinks --single-branch -b agents \
    ~/git/cowork ~/git/chuk_chat-merge
cd ~/git/chuk_chat-merge
git rev-list --count HEAD          # expect 306
```

### Stage 1 — path and package alignment (1.8 s; abort: `rm -rf` and redo stage 0)

```bash
cat > /tmp/cowork-replace.txt <<'EOF'
package:chuk_chat/==>package:chuk_chat/
regex:(?m)^name: agents$==>name: chuk_chat
EOF

~/.local/bin/git-filter-repo --force \
  --path-rename .gitignore:.gitignore.cowork-root \
  --path-rename README.md:README.agents.md \
  --path-rename app/: \
  --replace-text /tmp/cowork-replace.txt

# gates
test "$(git rev-list --count HEAD)" = 306
test -z "$(git grep -l 'package:agents' HEAD -- || true)"
git show HEAD:pubspec.yaml | head -1      # expect: name: chuk_chat
```

`filter-repo` removes the `origin` remote on purpose. Leave it removed.

### Stage 2 — bring upstream in (abort: `git merge --abort`)

```bash
git remote add upstream git@github.com:chuk-development/chuk_chat.git
git fetch upstream master:refs/remotes/upstream/master

git checkout -b cowork-integration upstream/master
git merge --allow-unrelated-histories --no-commit agents
```

Expect exit code 1 and **208** unmerged paths. Verify that the merge deletes
nothing before going on:

```bash
git diff --cached --diff-filter=D --name-only upstream/master | wc -l   # expect 0
git diff --name-only --diff-filter=U | wc -l                            # expect 208
```

**Never `git replace --graft` and never a merge with `d31526a` as the real base.**
Section 1 measures what that costs: 1067 silent deletions.

### Stage 3 — bucket resolution (abort: `git merge --abort`)

Resolve mechanically by bucket, with `d31526a` as the per-file base. Run this
from the repository root:

```bash
BASE=d31526a229fdde27c82adf3661d5d3a149db8340
for p in $(git diff --name-only --diff-filter=U); do
  case "$p" in *'~HEAD') continue;; esac
  cw=$(git rev-parse --verify -q "agents:$p")            || cw=
  up=$(git rev-parse --verify -q "upstream/master:$p")   || up=
  ba=$(git rev-parse --verify -q "$BASE:$p")             || ba=
  if   [ -n "$ba" ] && [ "$cw" = "$ba" ]; then git checkout --ours   -- "$p"
  elif [ -n "$ba" ] && [ "$up" = "$ba" ]; then git checkout --theirs -- "$p"
  else
    git cat-file blob "$up" > /tmp/m.ours
    if [ -n "$ba" ]; then git cat-file blob "$ba" > /tmp/m.base; else : > /tmp/m.base; fi
    git cat-file blob "$cw" > /tmp/m.theirs
    git merge-file -L 'upstream(master)' -L 'baseline(d31526a)' -L 'agents' \
        /tmp/m.ours /tmp/m.base /tmp/m.theirs || true
    rm -f -- "$p" && cp -f /tmp/m.ours "$p"    # rm first: AGENTS.md is a symlink
  fi
  git add -- "$p"
done
git rm -q --cached '.codex~HEAD' 'AGENTS.md~HEAD' 2>/dev/null || true
rm -f '.codex~HEAD' 'AGENTS.md~HEAD'
```

In this merge `--ours` is **upstream/master** and `--theirs` is **agents**. The
`rm -f` before the copy is not decoration: Agents's `AGENTS.md` is a symlink to
`CLAUDE.md`, and a plain `cp` writes through it and destroys `CLAUDE.md`.

Measured outcome: 16 take upstream, 83 take Agents, 29 merge clean, **78 files
left carrying conflict markers**, 0 unmerged index entries.

```bash
grep -rl '<<<<<<<' --exclude-dir=.git . | wc -l     # expect 78
```

### Stage 4 — identity override (abort: `git merge --abort`)

```bash
for p in linux/CMakeLists.txt linux/runner/my_application.cc .metadata \
         android/app/src/main/res/mipmap-hdpi/ic_launcher.png \
         android/app/src/main/res/mipmap-mdpi/ic_launcher.png \
         android/app/src/main/res/mipmap-xhdpi/ic_launcher.png \
         android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png \
         android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png ; do
  git checkout upstream/master -- "$p"
done
git rm -q android/app/src/main/kotlin/dev/chuk/cowork/MainActivity.kt
```

Then resolve `android/app/build.gradle.kts` and
`android/app/src/main/AndroidManifest.xml` towards `dev.chuk.chat`, keeping
Agents's `target-platform` ABI logic and `ic_notification.xml` / `colors.xml`
additions.

### Stage 5 — the 78 files by hand (abort: `git merge --abort`)

Order of work, cheapest first:

1. The 33 one-hunk and 13 two-hunk files — mostly an import line or a single guard.
2. `pubspec.yaml` (6 hunks): take the **union** of dependencies. Agents added
   `sqflite`, `sqflite_common_ffi`, `path`, `sqlite3_flutter_libs` and the two
   `third_party/` path dependencies; keep upstream's `name`, `description` and
   `version`.
3. The four `lib/l10n/strings_*.dart` files (11, 3, 3 hunks): both sides added
   keys. Take both sets.
4. `lib/pages/*` and `lib/widgets/*` (about 30 files, 2–12 hunks): Agents's edits
   are the Material 3 Expressive work in `docs/DESIGN.md`; upstream's are
   `settings_kit` / `floating_chrome_surface` refactors. Prefer upstream's
   structure and re-apply Agents's styling on top.
5. `lib/widgets/sidebar/sidebar_chrome.dart` (19 hunks, 1044 upstream lines
   added): almost pure upstream rework. Take upstream, re-apply Agents's 112
   lines.
6. `lib/platform_specific/chat/chat_ui_desktop.dart` (11 hunks) and
   `chat_ui_mobile.dart` (**61 hunks**): last, and budget a full session. Both
   sides rewrote large parts. Take upstream's file as the skeleton (it carries
   the `chat_message_list_item.dart` split), then port Agents's changes hunk by
   hunk. Delete `lib/platform_specific/chat/widgets/desktop_chat_widgets.dart`
   when done.

### Stage 6 — post-move fixups and gates (abort: `git merge --abort`)

`filter-repo` moved the files but not the strings inside them. Six functional
places still say `app/`:

| File | Fix |
|---|---|
| `scripts/build_apk.sh` | `APP_DIR="$REPO/app"` → `APP_DIR="$REPO"` |
| `scripts/capture_app_window.sh` | `$project_root/app/build/linux/…/agents` → `$project_root/build/linux/…/chuk_chat` |
| `scripts/import_chat_ui.sh` | **delete the file** — the import is over |
| `executor/tests/test_mcp_adopt_credentials.py` | `parents[2] / "app/test/fixtures/…"` → `parents[1] / "test/fixtures/…"` |
| `executor/tests/test_mcp_credentials_frame.py` | same |
| `executor/tests/test_mcp_signature.py` | same |

Then fold `.gitignore.cowork-root` (the Python and Beads rules) into the root
`.gitignore` and delete it; fold `README.agents.md` into `README.md` and delete
it; retire `tools/chat_ui_manifest.txt` and `docs/CHAT_UI_IMPORT.md`, or reduce
them to a note that says the import is finished.

Gates before the commit:

```bash
grep -rl '<<<<<<<' --exclude-dir=.git . | wc -l    # expect 0
flutter pub get && flutter analyze                 # expect 0 errors
flutter test
( cd agent     && uv run pytest )
( cd executor  && uv run pytest )
( cd host      && uv run pytest )
( cd sandbox   && uv run pytest )
scripts/build_apk.sh --emulator                    # Agents mode still builds
```

Commit as a real merge, so both histories stay reachable:

```bash
git commit -m "merge(agents): one app — Agents rides on chuk_chat master"
git log --oneline --graph -3
git rev-list --count HEAD           # expect 1680 = 1373 + 306 + 1
```

Up to here, everything can be thrown away with `rm -rf ~/git/chuk_chat-merge`.

### Stage 7 — publish. **This is the point of no return**

```bash
git push upstream cowork-integration:master
```

After this push:

* The Agents commits exist on `chuk-development/chuk_chat` under **new SHAs**.
  `filter-repo` rewrote all 306. Any clone that still holds the old SHAs
  (`/home/user/git/cowork`, and the `agents` branch already on the remote) is
  orphaned from the new history.
* **Leave the existing remote `agents` branch alone.** Do not force-push over it.
  It is the only copy of the pre-rewrite SHAs and it costs nothing to keep. Tag
  it before the push: `git push upstream refs/remotes/origin/agents:refs/tags/cowork-pre-merge`
  from a clone that still has the old history.
* Everyone who works in `/home/user/git/cowork` must re-clone. That tree cannot
  be rebased onto the new history, because every commit changed.

Only push when `flutter analyze`, `flutter test`, the four pytest suites and one
real `scripts/build_apk.sh --emulator` run have all passed on the merge commit.

## 7. Abort table

| Stage | State | Abort |
|---|---|---|
| 0 | scratch clone exists | `rm -rf ~/git/chuk_chat-merge` |
| 1 | history rewritten in the scratch clone | `rm -rf ~/git/chuk_chat-merge`, redo stage 0 |
| 2 | merge in progress, 208 unmerged | `git merge --abort` |
| 3 | buckets resolved, 78 files with markers | `git merge --abort` |
| 4 | identity overridden | `git merge --abort` |
| 5 | 78 files resolved by hand | `git merge --abort` (loses the hand work — commit to a WIP branch first) |
| 6 | merge commit made, nothing pushed | `git checkout upstream/master && git branch -D cowork-integration`, or `rm -rf` the clone |
| 7 | **pushed** | no abort. Only `git push --force` back to `a249a54`, which then orphans anything pulled in between. |

## 8. Summary

The graft costs 1067 silently deleted upstream files and 201 conflicts. The
unrelated-histories merge costs **78 files / 301 hunks** and deletes nothing. One
of those 78 (`chat_ui_mobile.dart`) holds 61 hunks, a fifth of the whole job. The
Python half — 317 files across six directories — moves across with zero
collisions. The path rewrite itself takes under two seconds and preserves all 306
commits.

## 9. Execution log — 2026-09-13, clone at `/home/user/git/agents-merge`

Everything below was run in a throwaway clone. `/home/user/git/cowork` and
`/home/user/git/chuk_chat` were only read. Nothing was pushed. The clone is left
mid-merge (`MERGE_HEAD` set, index fully resolved) so a human can inspect it.

```bash
rm -rf /home/user/git/agents-merge
git clone --no-hardlinks --single-branch -b agents \
    /home/user/git/cowork /home/user/git/agents-merge
```

### 9.1 What the rename to Agents already did — the no-ops

Commit `b57c5ce` ("the product is Agents") did part of stage 1 ahead of time.
After it, these runbook steps do nothing and were dropped:

| Runbook step | Status now |
|---|---|
| `--replace-text` rule `package:cowork/==>package:chuk_chat/` | **no-op** — 0 files carry `package:cowork`; 416 already carry `package:chuk_chat/` |
| `--replace-text` rule `^name: cowork$==>name: chuk_chat` | **no-op** — `app/pubspec.yaml` line 1 already reads `name: chuk_chat` |
| The gate `git grep -l 'package:cowork'` | passes trivially |
| The gate `git show HEAD:pubspec.yaml \| head -1` | already `name: chuk_chat` before the rewrite |

The whole `/tmp/cowork-replace.txt` file can be deleted from stage 1. The two
`--path-rename` rules for the root `.gitignore` / `README.md` are still needed:
without them `app/.gitignore` and `app/README.md` cannot land at the root.

Also renamed by `b57c5ce` and worth knowing: the Dart service folder is
`lib/services/agents/`, the Python distributions are `chuk_agents_*`, and
`docs/COWORK_AGENT_PLATFORM_PLAN.md` became `docs/AGENTS_AGENT_PLATFORM_PLAN.md`.
That last rename is the reason one bucket number moved (see 9.4).

### 9.2 Numbers that no longer match the runbook

| Measure | Runbook (2026-09-13, pre-rename) | Now | Why |
|---|---:|---:|---|
| Agents commits | 306 | **312** | six rename commits |
| Agents tracked files | 1330 | **1337** | |
| Files under `app/` | 875 | **876** | |
| chuk_chat `master` commits / files | 1373 / 1580 | 1373 / 1580 | unchanged |
| Baseline `d31526a` files | 1338 | 1338 | unchanged |
| Unmerged paths after stage 2 | 208 | **207** | one collision fewer |
| Colliding paths | 410 | **409** | `docs/COWORK_AGENT_PLATFORM_PLAN.md` no longer collides |
| Byte-identical on both sides | 204 | 204 | unchanged |
| Pure upstream drift → take upstream | 16 | 16 | same 16 files, list verified |
| Pure Agents divergence → take Agents | 83 | **82** | the platform-plan doc left this bucket |
| Both edited, three-way merge clean | 29 | 29 | |
| **Both edited, conflicts by hand** | **78** | **78** | **exactly the same 78 files** |
| Conflict hunks in those 78 | 301 | **266** | |
| `chat_ui_mobile.dart` hunks | 61 | **45** | still the worst file by far |
| Agents-only additions | 920 (317 Python) | **928** (324 under `agents/`) | |
| Upstream-only files | 1170 | **1171** | |
| Union after the merge | 2500 | **2508** | |
| Upstream files deleted by the merge | 0 | **0** | the runbook's central claim holds |
| `filter-repo` wall time | 1.8 s | **1.1 s** | |

The list of 78 conflicting files is **identical** to section 3's list, file for
file. Only the hunk counts fell.

### 9.3 One thing in the runbook is wrong

`git ls-remote` says the published `chuk-development/chuk_chat` `master` is
**`fe7195d`**, not `a249a54`. `a249a54` is a local, unpushed commit sitting on
`master` in `/home/user/git/chuk_chat`. The runbook measured against the local
tip. This execution kept that choice — `upstream/master` here was fetched from
`/home/user/git/chuk_chat` and is `a249a54` — so stage 7 publishes that commit
too. Decide deliberately before pushing.

Second, smaller: the stage-3 and stage-6 gates
`grep -rl '<<<<<<<' --exclude-dir=.git . | wc -l` can never print 0, because
**this file** contains the literal marker inside those very commands, and this
file is part of the merged tree. Use

```bash
grep -rl '<<<<<<<' --exclude-dir=.git --exclude=MERGE_INTO_CHUK_CHAT.md . | wc -l
```

### 9.4 Stage 1 — one filter-repo pass, including the Python move

The user asked for the Python side under one directory. That went into the
**same** `filter-repo` invocation as the `app/` → root move, not a later
`git mv`. Reason: one rewrite, no orphan rename commit, and every one of the 312
commits ends up with the final layout — a `git mv` would leave the old paths in
all 312 commits next to a root that had already moved.

```bash
git-filter-repo --force \
  --path-rename .gitignore:.gitignore.agents-root \
  --path-rename README.md:README.agents.md \
  --path-rename agent/:agents/runtime/ \
  --path-rename executor/:agents/executor/ \
  --path-rename host/:agents/host/ \
  --path-rename manager/:agents/manager/ \
  --path-rename sandbox/:agents/sandbox/ \
  --path-rename common/:agents/common/ \
  --path-rename skills/:agents/skills/ \
  --path-rename app/:
```

Result: 312 → 312 commits, none pruned, 1337 files, 0 `app/` paths left in any
commit, `HEAD:pubspec.yaml` still `name: chuk_chat`. Rule order matters — the two
root renames must come before `app/:`, or the Flutter `.gitignore` and
`README.md` collide on the way to the root.

The layout after the pass:

```
/                      the Flutter app (lib/ android/ linux/ test/ assets/ …)
/agents/runtime/       was agent/
/agents/executor/      was executor/
/agents/host/          was host/
/agents/manager/       was manager/
/agents/sandbox/       was sandbox/
/agents/common/        was common/   (chuk_agents_config, chuk_agents_crypto)
/agents/skills/        was skills/
/scripts /docs /tools /extension /supabase /third_party   unchanged
```

### 9.5 What the move broke, and the fix

Everything below is an edit in the working tree of the clone, already applied.

| File | Change |
|---|---|
| `agents/executor/pyproject.toml`, `agents/host/pyproject.toml` | `{ path = "../agent" }` → `{ path = "../runtime" }`. The other five path deps keep working — the move preserved the depth, so `../sandbox`, `../manager`, `../executor`, `../common/chuk_agents_*` are all still correct. |
| `agents/*/uv.lock` | same rename for `editable = "../agent"` |
| `agents/runtime/tests/test_live_model.py` | `parents[2]` → `parents[3]`; dropped the now-duplicate `REPO_ROOT / "app" / ".env"` candidate |
| `agents/runtime/tests/test_mcp_client.py` | `parents[2] / "app" / "test" / …` → `parents[3] / "test" / …` |
| `agents/host/tests/test_install_script.py` | `parents[2]` → `parents[3]`, and `REPO_ROOT / "host" / ".venv"` → `REPO_ROOT / "agents" / "host" / ".venv"` (this one only showed up when the suite ran) |
| `agents/executor/src/chuk_agents_executor/protocol.py` | `parents[3]` → `parents[4]` for `tools/agents-extension-mcp/` |
| `agents/common/chuk_agents_config/tests/test_env_coverage.py` | `parents[3]` → `parents[4]`; `SEARCH_DIRS` now `agents/runtime/src`, `agents/executor/src`, `agents/manager/src`, `agents/sandbox`, `agents/host`, `scripts`; the checkout probe is `agents/runtime/src` |
| `agents/executor/tests/test_mcp_adopt_credentials.py`, `test_mcp_credentials_frame.py`, `test_mcp_signature.py` | `parents[2] / "app/test/fixtures/…"` → `parents[3] / "test/fixtures/…"` (the runbook's stage-6 item, plus one level for the move) |
| `scripts/install.sh` | `${REPO_ROOT}/host` → `${REPO_ROOT}/agents/host`; `sandbox/docker` → `agents/sandbox/docker` everywhere |
| `scripts/build_apk.sh` | `APP_DIR="$REPO/app"` → `APP_DIR="$REPO"`, and the `app/.env` prose |
| `scripts/capture_app_window.sh` | `$project_root/app/build/linux/x64/debug/bundle/agents` → `$project_root/build/linux/x64/debug/bundle/chuk_chat` |
| `scripts/import_chat_ui.sh` | deleted — the import is over |
| `.github/workflows/images.yml` | build context and `file:` → `agents/sandbox/docker/…` |
| `README.agents.md` | the layout table now names `agents/*` and says the Flutter app is the root |
| `agents/host/src/chuk_agents_host/doctor.py`, `agents/runtime/src/chuk_agents_runtime/browser.py`, `agents/runtime/pyproject.toml`, `agents/sandbox/docker/Dockerfile.browser`, `agents/sandbox/docker/vnc-up.sh`, `agents/executor/tests/live_reasoning_probe.py`, `lib/utils/automation_message.dart`, four Dart tests | cross-reference paths in comments and user-facing messages (`sandbox/docker/…`, `agent/tests/…`, `executor/tests/…`) |

Two things did **not** need a change, against expectation:

* `scripts/agents-manager.service` carries no repository-relative path at all —
  it is written from `@EXEC@` / `@AGENTS_HOME@` placeholders that `install.sh`
  substitutes with absolute paths.
* `agents/host/src/chuk_agents_host/seed_skills.py` walks up its own parents
  looking for a `skills/` sibling. After the move it finds `agents/skills/` one
  level earlier and needs no edit. Proven by `test_seed_skills.py`, not assumed.

`test/fixtures/mcp_forward_payload.json` was deliberately left byte-identical:
it is signed material for `agents/executor/tests/test_mcp_signature.py`, so its
stale `agent/tests/…` comment stays.

The historical `docs/HANDOVER_*`, `docs/PLAN_*` and `docs/PROMPT_*` files still
name the old directories. They are dated records; rewriting them would falsify
history. `docs/FILE_MAP.md`, `docs/ARCHITECTURE.md` and `docs/COMMON_TASKS.md`
never named the Python directories, so they needed nothing.

### 9.6 Stage 2 and 3 — the merge and the buckets

```bash
git remote add upstream git@github.com:chuk-development/chuk_chat.git
git fetch /home/user/git/chuk_chat master:refs/remotes/upstream/master
git checkout -b agents-integration upstream/master
git merge --allow-unrelated-histories --no-commit agents
```

207 unmerged paths, **0 upstream files staged for deletion**. The bucket loop
from section 3 then ran unchanged (with its temporary files inside the clone
instead of `/tmp`), and the `~HEAD` leftovers were removed:

```
take upstream (pure drift)      16
take Agents (pure divergence)   82
three-way merge succeeded       29
conflict markers left           78
byte-identical, git resolved   204
                              ----
colliding paths                409
```

Afterwards: `git ls-files -u` is empty, `MERGE_HEAD` is still set, 2505 tracked
files.

One wrinkle the runbook does not mention: after resolving `.codex`, git leaves
the *directory* unmaterialized in the working tree even though the index holds
`.codex/config.toml` and `.codex/hooks.json`. Run `git checkout -- .codex` after
deleting `.codex~HEAD`.

### 9.7 Stage 4 — identity, and three silent takeovers

The eight prescribed files were forced to upstream and
`android/app/src/main/kotlin/dev/chuk/cowork/MainActivity.kt` was deleted.

**The marker grep does not catch everything.** Three identity lines came through
the merge without a conflict, each taking the Agents value, each one a shipped-app
regression:

| File | Line as merged | Must become |
|---|---|---|
| `android/app/build.gradle.kts` | `applicationId = "dev.chuk.cowork"` (line 46, no markers) | `dev.chuk.chat` — otherwise every installed copy loses update continuity |
| `android/app/src/main/AndroidManifest.xml` | `android:label="Temporär-Agents"` (line 24, no markers) | upstream's label |
| `pubspec.yaml` | `version: 1.0.0+1` (no markers) | upstream's `version: 1.0.109` — a lower versionCode is rejected by Play |

`android/app/build.gradle.kts` *also* has a 1-hunk conflict on `namespace` /
`compileSdk`; resolving that one does not fix the three lines above.

Two more leftovers for stage 6:

* `docs/COWORK_AGENT_PLATFORM_PLAN.md` (upstream's, 43 KB) and
  `docs/AGENTS_AGENT_PLATFORM_PLAN.md` (Agents's, 77 KB) now both exist. They no
  longer collide because of the rename. Delete the upstream one.
* Upstream's `.gitignore` ignores `/tools/` at the root. Agents has a real
  `tools/` directory (`agents-browser-bridge`, `agents-extension-mcp`,
  `chat_ui_manifest.txt`). Whoever resolves the `.gitignore` conflict must not
  keep that line as it stands.
* `linux/flutter/generated_plugin_registrant.cc`, `linux/flutter/generated_plugins.cmake`
  and `linux/runner/my_application.h` fell in the "take Agents" bucket. They are
  generated from the merged dependency list and will be rewritten by the first
  `flutter pub get` / build after `pubspec.yaml` is resolved.

### 9.8 What actually runs right now

| Suite | Result |
|---|---|
| `agents/common/chuk_agents_crypto` — `uv run pytest -q` | **65 passed** |
| `agents/common/chuk_agents_config` — `uv run pytest -q` | **63 passed** (including the env-coverage test that reads the new `SEARCH_DIRS`) |
| `agents/sandbox` — `uv run pytest -q` | **107 passed** |
| `agents/manager` — `uv run pytest -q` | **183 passed** |
| `agents/runtime` — `uv run pytest -q` | **964 collected, exit 0** (4 skipped; the package's own `addopts = "-q"` plus a second `-q` suppresses the summary line) |
| `agents/host` — `uv run pytest -q` | **281 passed** |
| `agents/executor` — `uv run pytest -q` | **234 passed, 1 failed** |
| `bash scripts/tests/test_rename_to_agents.sh` | **53 passed, 0 failed** |
| `flutter pub get` → `flutter analyze` | **cannot run** |

The one executor failure is
`tests/test_regenerate.py::test_four_retries_replay_the_question_once`:
the replayed user frame now carries a `created_at` field the test does not
expect. It is **not** caused by the merge or the move — it reproduces
deterministically on the untouched `agents` branch in a separate worktree, with
nothing from upstream present. It came in with the Agents branch and needs its
own fix.

`flutter analyze` is blocked at the first step: `pubspec.yaml` carries conflict
markers, so the YAML parse fails at line 23 and `flutter pub get` aborts before
it resolves anything. This is expected at this point in the runbook — analyze
cannot say anything useful until the 78 files are resolved. Resolve
`pubspec.yaml` first (stage 5 item 2) and analyze becomes available again even
while other files still carry markers.

### 9.9 The 78 files still carrying conflict markers

266 hunks over 78 files. `kinds` counts each hunk: `body` = both sides changed
the same lines, `upstream-add` / `agents-add` = only that side put something
there, `import` = the hunk is nothing but import lines, `format` = the two sides
are identical once whitespace is removed (only 4 hunks in the whole set — there
is no formatting-only shortcut here).

Three themes cover most of it. First, Agents replaced upstream's chrome widgets
with its own Material 3 Expressive kit, so the import block of almost every page
and widget diverges: upstream's `widgets/floating_app_bar.dart`,
`widgets/settings_list_view.dart`, `widgets/app_notification.dart` and
`l10n/app_localizations.dart` against Agents's `ui/expressive/expressive_screen.dart`,
`ui/expressive/icon_map.dart` and `ui/expressive/staggered.dart`. Second, both
sides edited the same `AppIcon(...)` call sites, with different icon logic on
each side. Third, Agents added connector strings to the `l10n/strings_*.dart`
tables while upstream reworked the same files — take both sets.

| hunks | kinds | file | first divergence (upstream \|\| agents) |
|---:|---|---|---|
| 45 | 34xbody, 5xupstream-add, 3ximport, 3xagents-add | `lib/platform_specific/chat/chat_ui_mobile.dart` | upstream: import 'package:flutter/rendering.dart' show ScrollCacheExtent; \|\| agents: import 'package:chuk_chat/ui/expressive/icon_map.dart'; |
| 16 | 15xbody, 1ximport | `lib/widgets/sidebar/sidebar_chrome.dart` | upstream: import 'package:chuk_chat/l10n/app_localizations.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/icon_map.dart'; |
| 14 | 12xbody, 1ximport, 1xagents-add | `lib/platform_specific/chat/chat_ui_desktop.dart` | upstream: import 'package:flutter/rendering.dart' show ScrollCacheExtent; \|\| agents: import 'package:chuk_chat/ui/expressive/icon_map.dart'; |
| 11 | 7xagents-add, 4xbody | `lib/l10n/strings_fr.dart` | upstream: (nothing) \|\| agents: 'catEmailImapSmtpDesc': 'Envoyer et recevoir des e-mails via IMAP et SMT… |
| 10 | 8xbody, 1ximport, 1xagents-add | `lib/pages/account_settings_page.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/expressive_screen.dart'; |
| 9 | 8xbody, 1ximport | `lib/model_selector_page.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/icon_map.dart'; |
| 7 | 3xupstream-add, 3xbody, 1ximport | `lib/pages/settings_page.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/icon_map.dart'; |
| 7 | 7xbody | `lib/pages/about_page.dart` | upstream: import 'dart:async'; \|\| agents: // AGENTS ADAPTATION (chuk_chat/lib/pages/about_page.dart), line by line… |
| 6 | 4xbody, 2ximport | `lib/pages/skills_settings_page.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/huge_icon.dart'; |
| 6 | 5xbody, 1ximport | `lib/pages/login_page.dart` | upstream: import 'package:chuk_chat/supabase_config.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/motion.dart'; |
| 5 | 5xbody | `pubspec.yaml` | upstream: sdk: ^3.9.2 \|\| agents: sdk: ^3.11.5 |
| 5 | 4xbody, 1xupstream-add | `lib/widgets/sandbox_artifact_block.dart` | upstream: import 'package:chuk_chat/utils/format_bytes.dart'; \|\| agents: import 'package:chuk_chat/widgets/chat_document_inline.dart'; |
| 5 | 4xbody, 1xagents-add | `lib/widgets/menu_tile_group.dart` | upstream: import 'package:flutter/material.dart'; \|\| agents: // lib/widgets/menu_tile_group.dart |
| 5 | 5xbody | `lib/services/mcp/mcp_service.dart` | upstream: import 'package:chuk_chat/services/mcp/mcp_sync_service.dart'; \|\| agents: import 'package:chuk_chat/services/agents/agents_relay_link.dart'; |
| 5 | 3xbody, 1ximport, 1xformat | `lib/pages/recover_chats_page.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/expressive_screen.dart'; |
| 5 | 3xbody, 2xupstream-add | `lib/pages/desktop_settings_modal.dart` | upstream: import 'package:chuk_chat/widgets/app_notification.dart'; \|\| agents: (nothing) |
| 5 | 2xupstream-add, 2xbody, 1ximport | `lib/pages/customization_page.dart` | upstream: import 'package:chuk_chat/widgets/icons/icon_map.dart'; \|\| agents: import 'package:chuk_chat/widgets/menu_tile_group.dart'; |
| 4 | 3xbody, 1ximport | `lib/widgets/attachment_preview_bar.dart` | upstream: import 'package:chuk_chat/constants.dart'; \|\| agents: import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart'; |
| 4 | 4xbody | `lib/platform_specific/chat/desktop_send_logic.dart` | upstream: ? captureRegenSeed(index) \|\| agents: ? _captureRegenSeed(index) |
| 4 | 2ximport, 1xbody, 1xupstream-add | `lib/pages/theme_page.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/expressive_screen.dart'; |
| 3 | 2xbody, 1ximport | `lib/widgets/model_selection_dropdown.dart` | upstream: import 'package:chuk_chat/widgets/app_notification.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/icon_map.dart'; |
| 3 | 2xbody, 1xformat | `lib/platform_specific/chat/widgets/mobile_chat_widgets.dart` | upstream: (nothing) \|\| agents: (nothing) |
| 3 | 2xbody, 1ximport | `lib/pages/fullscreen_map_page.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/motion.dart'; |
| 3 | 3xagents-add | `lib/l10n/strings_pt.dart` | upstream: (nothing) \|\| agents: 'profileSubtitle': 'Atualize como seu nome e email aparecem no Chuk Chat… |
| 3 | 3xagents-add | `lib/l10n/strings_es.dart` | upstream: (nothing) \|\| agents: 'catEmailImapSmtpDesc': 'Enviar y recibir correo electrónico por IMAP y … |
| 2 | 2xbody | `test/pages/skills_settings_page_test.dart` | upstream: import 'package:chuk_chat/services/skills/builtin_skills.g.dart'; \|\| agents: import 'package:chuk_chat/services/agents/agents_relay_client.dart'; |
| 2 | 1xupstream-add, 1xbody | `lib/widgets/workspace_selection_dropdown.dart` | upstream: import 'package:chuk_chat/models/workspace_model.dart'; \|\| agents: (nothing) |
| 2 | 1ximport, 1xbody | `lib/widgets/workspace_panel.dart` | upstream: import 'package:flutter/foundation.dart'; \|\| agents: import 'package:flutter/material.dart'; |
| 2 | 1ximport, 1xbody | `lib/widgets/workspace_file_viewer.dart` | upstream: import 'package:flutter/foundation.dart'; \|\| agents: import 'package:chuk_chat/models/workspace_model.dart'; |
| 2 | 2xbody | `lib/widgets/route_map_widget.dart` | upstream: child: const AppIcon(Icons.trip_origin, color: Colors.green, size: 28), \|\| agents: child: const AppIcon( |
| 2 | 2xbody | `lib/widgets/nice_snackbar.dart` | upstream: return AppNotifications.show( \|\| agents: final messenger = ScaffoldMessenger.of(context); |
| 2 | 2xbody | `lib/widgets/image_viewer.dart` | upstream: appBar: AppBar( \|\| agents: titleWidget: _hasMultipleImages |
| 2 | 1ximport, 1xbody | `lib/widgets/document_viewer.dart` | upstream: import 'package:chuk_chat/widgets/app_notification.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/motion.dart'; |
| 2 | 1xupstream-add, 1xbody | `lib/widgets/anchored_menu.dart` | upstream: // No box around the menu: every row is its own filled tile, and a \|\| agents: (nothing) |
| 2 | 1xbody, 1xagents-add | `lib/services/workspace_storage_service.dart` | upstream: final workspace = _projectsById[workspaceId]; \|\| agents: static Future<void> removeChatFromProject( |
| 2 | 2xbody | `lib/services/title_generation_service.dart` | upstream: // lib/services/title_generation_service.dart \|\| agents: // AGENTS STUB. Upstream: chuk_chat/lib/services/title_generation_servic… |
| 2 | 2xagents-add | `lib/services/image_storage_service.dart` | upstream: (nothing) \|\| agents: static Future<int> getImageSize(String storagePath) async { |
| 2 | 1ximport, 1xbody | `lib/services/artifact_storage_service.dart` | upstream: import 'package:chuk_chat/services/artifact_diff_engine.dart'; \|\| agents: import 'package:flutter/foundation.dart'; |
| 2 | 1xagents-add, 1xbody | `lib/platform_specific/chat/widgets/fullscreen_composer.dart` | upstream: (nothing) \|\| agents: import 'package:chuk_chat/ui/expressive/icon_map.dart'; |
| 2 | 1ximport, 1xbody | `lib/pages/workspace_management_page.dart` | upstream: import 'package:flutter/material.dart'; \|\| agents: import 'package:chuk_chat/pages/coming_soon_page.dart'; |
| 2 | 2xbody | `lib/pages/usage_details_page.dart` | upstream: import 'package:flutter/material.dart'; \|\| agents: // AGENTS STUB. Upstream: chuk_chat/lib/pages/usage_details_page.dart @ … |
| 2 | 2xbody | `lib/pages/pricing_page.dart` | upstream: import 'dart:convert'; \|\| agents: // AGENTS STUB. Upstream: chuk_chat/lib/pages/pricing_page.dart @ d31526… |
| 2 | 1ximport, 1xbody | `lib/pages/coming_soon_page.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/expressive_screen.dart'; |
| 2 | 2xbody | `lib/main.dart` | upstream: import 'package:flutter_riverpod/flutter_riverpod.dart'; \|\| agents: import 'package:shared_preferences/shared_preferences.dart'; |
| 2 | 1xbody, 1xupstream-add | `android/app/src/main/AndroidManifest.xml` | upstream: <uses-permission android:name="android.permission.WAKE_LOCK" /> \|\| agents: <uses-permission android:name="android.permission.VIBRATE" /> |
| 1 | 1ximport | `test/widgets/composer_recording_row_test.dart` | upstream: import 'package:chuk_chat/widgets/waveform.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/waveform.dart'; |
| 1 | 1xagents-add | `test/support/kv_cache_test_env.dart` | upstream: (nothing) \|\| agents: // |
| 1 | 1xbody | `README.md` | upstream: --- \|\| agents: For help getting started with Flutter development, view the |
| 1 | 1xbody | `lib/widgets/weather_widget.dart` | upstream: AppIcon( \|\| agents: AppIcon(_iconForCode(code), size: 64, color: Colors.white), |
| 1 | 1ximport | `lib/widgets/settings_list_view.dart` | upstream: import 'package:chuk_chat/widgets/floating_app_bar.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/staggered.dart'; |
| 1 | 1ximport | `lib/widgets/per_model_system_prompt_sheet.dart` | upstream: import 'package:chuk_chat/widgets/app_notification.dart'; \|\| agents: import 'package:chuk_chat/ui/expressive/icon_map.dart'; |
| 1 | 1xbody | `lib/widgets/message_bubble/web_search_sources.dart` | upstream: final Widget fallback = AppIcon(Icons.public_rounded, size: 14, color: m… \|\| agents: final Widget fallback = AppIcon( |
| 1 | 1xbody | `lib/widgets/message_bubble/tools.dart` | upstream: AppIcon( \|\| agents: AppIcon(Icons.smart_toy_outlined, size: 13, color: muted), |
| 1 | 1xagents-add | `lib/widgets/message_bubble/rich_blocks.dart` | upstream: (nothing) \|\| agents: dynamic _tryParseJson(String raw) { |
| 1 | 1xbody | `lib/widgets/message_bubble/layout.dart` | upstream: hasWorkedFor \|\| \|\| agents: (isWaitingForFirstTokens && !widget.messengerMode)) && |
| 1 | 1xbody | `lib/widgets/message_bubble/chrome.dart` | upstream: showModalBottomSheet<void>( \|\| agents: final String label = |
| 1 | 1xformat | `lib/widgets/message_bubble/cards.dart` | upstream: _notFound ? Icons.image_not_supported_outlined : Icons.broken_image, \|\| agents: _notFound |
| 1 | 1xbody | `lib/widgets/credit_display.dart` | upstream: Builder(builder: (context) { \|\| agents: Builder( |
| 1 | 1xbody | `lib/widgets/chuk_table.dart` | upstream: return Material( \|\| agents: // The confirmation travels: fill and glyph move to the accent and back … |
| 1 | 1xbody | `lib/widgets/accent_icon_button.dart` | upstream: final ThemeData theme = Theme.of(context); \|\| agents: final Color fill = accent ?? Theme.of(context).colorScheme.primary; |
| 1 | 1xbody | `lib/tool_handlers/notes_tools.dart` | upstream: import 'dart:convert'; \|\| agents: // AGENTS STUB. Upstream: chuk_chat/lib/tool_handlers/notes_tools.dart. |
| 1 | 1xbody | `lib/services/workspace_message_service.dart` | upstream: return buffer.toString(); \|\| agents: static Future<List<Map<String, dynamic>>> injectProjectContext( |
| 1 | 1xbody | `lib/services/supabase_service.dart` | upstream: initializedListenable.value = true; \|\| agents: SessionRefreshScheduler.instance.start(); |
| 1 | 1xbody | `lib/services/streaming_transcription_service.dart` | upstream: /// Timeout for establishing the WebSocket connection. \|\| agents: bool get isConnected => false; |
| 1 | 1xagents-add | `lib/services/streaming_manager_stub.dart` | upstream: (nothing) \|\| agents: // Map of chatId -> ActiveStream |
| 1 | 1xagents-add | `lib/services/streaming_manager_io.dart` | upstream: (nothing) \|\| agents: if (event is FinalContentEvent) { |
| 1 | 1xbody | `lib/services/offline_retry_manager.dart` | upstream: _events.add(event); \|\| agents: _events.add( |
| 1 | 1xbody | `lib/services/file_conversion_service.dart` | upstream: }) async { \|\| agents: }) async => Map<String, dynamic>.from(_unavailable); |
| 1 | 1xformat | `lib/services/chat_storage_sidebar.dart` | upstream: final prefs = sharedPrefsInstance ?? await SharedPreferences.getInstance… \|\| agents: final prefs = |
| 1 | 1xbody | `lib/services/chat_preload_service.dart` | upstream: final title = \|\| agents: final title = existing?.title ?? _extractTitle(chatPayload.messages); |
| 1 | 1xagents-add | `lib/platform_specific/chat/handlers/file_attachment_handler.dart` | upstream: (nothing) \|\| agents: /// Replace a scanned PDF with its rendered pages. |
| 1 | 1xupstream-add | `lib/platform_specific/chat/chat_ui_helpers.dart` | upstream: /// Owns decoded message payloads for one visible chat and builds render… \|\| agents: (nothing) |
| 1 | 1xupstream-add | `lib/platform_specific/chat/chat_scroll_mixin.dart` | upstream: // And the reader has read past the pinned message, so the room held \|\| agents: (nothing) |
| 1 | 1xbody | `.gitignore` | upstream: # Build artifacts and packages \|\| agents: # Golden-diff output from a failing image comparison (flutter_test write… |
| 1 | 1xbody | `CLAUDE.md` | upstream: **`docs/COWORK_EXECUTION_PLAN.md`** is the live, ordered build plan for … \|\| agents: <!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 --> |
| 1 | 1xbody | `.beads/interactions.jsonl` | upstream: {"id":"int-dd1cd72807422abc96f42df9aa233b4d","kind":"field_change","crea… \|\| agents: {"id":"int-41d0ced4da1f06db0c8ce2220289dc7e","kind":"field_change","crea… |
| 1 | 1xbody | `android/app/build.gradle.kts` | upstream: namespace = "dev.chuk.chat" \|\| agents: namespace = "dev.chuk.cowork" |
| 1 | 1xbody | `AGENTS.md` | upstream: # AGENTS.md \|\| agents: CLAUDE.md |

### 9.10 Stage 5 onwards — what the next agents get

Unchanged from section 5, with these corrections: `chat_ui_mobile.dart` is 45
hunks, not 61; `chat_ui_desktop.dart` is 14, not 11; `sidebar_chrome.dart` is 16,
not 19. `lib/widgets/menu_tile_group.dart` is no longer a one-hunk add/add — it
is 5 hunks. Deleting
`lib/platform_specific/chat/widgets/desktop_chat_widgets.dart` after resolving
the two chat screens is still the right move; upstream's replacement
`lib/platform_specific/chat/widgets/chat_message_list_item.dart` is present in
the merged tree.

Still open from stage 6, deliberately left for the next pass because each one
needs a conflicted file resolved first:

* fold `.gitignore.agents-root` into the root `.gitignore` (drop upstream's
  `/tools/` line) and delete it
* fold `README.agents.md` into `README.md` and delete it
* retire `tools/chat_ui_manifest.txt` and `docs/CHAT_UI_IMPORT.md`
* delete `docs/COWORK_AGENT_PLATFORM_PLAN.md`
* the three silent identity lines in 9.7
* file a bead for the pre-existing `test_four_retries_replay_the_question_once`
  failure

### 9.11 Stage 7 — the exact commands, for the user only

Nothing here was run. Run it only after `flutter analyze`, `flutter test`, the
seven pytest suites and one real `scripts/build_apk.sh --emulator` all pass on
the merge commit.

```bash
cd /home/user/git/agents-merge

# 0. the gates
grep -rl '<<<<<<<' --exclude-dir=.git --exclude=MERGE_INTO_CHUK_CHAT.md . | wc -l   # 0
flutter pub get && flutter analyze && flutter test
for p in runtime executor host manager sandbox common/chuk_agents_config common/chuk_agents_crypto; do
  ( cd "agents/$p" && uv run pytest -q ) || echo "FAILED: $p"
done
scripts/build_apk.sh --emulator

# 1. the merge commit
git commit -m "merge(agents): one app — Agents rides on chuk_chat master"
git rev-list --count HEAD          # expect 1686 = 1373 + 312 + 1

# 2. keep the pre-rewrite SHAs reachable, from a clone that still has them
git -C /home/user/git/cowork push origin \
    refs/remotes/origin/agents:refs/tags/agents-pre-merge

# 3. the point of no return
git push upstream agents-integration:master
```

Note that step 3 also publishes `a249a54`, which is currently unpushed (9.3).
Leave the remote `agents` branch alone afterwards — it is the only copy of the
pre-rewrite SHAs — and re-clone `/home/user/git/cowork`; it cannot be rebased
onto the new history, because all 312 commits changed SHA.

## 10. Close-out — measured gate (2026-09-13, coordinator)

All 78 marker files are resolved and the tree carries no conflict marker. The
duplicated `AppIcon` / `LiveWaveform` copies under `ui/expressive/` are now
re-export shims onto `widgets/`, so each class exists once again — two classes of
the same name make `widget is AppIcon` false across the boundary, which breaks
every test that finds an icon by widget type. The orphaned Agents mixin family
(~2.5k lines) is deleted.

### Analyze

`flutter analyze`: **24 issues, 1 error**, down from 3991. The one error is
`ToolLoopSession.enforcer` in `test/services/tool_call_handler_safety_limit_test.dart`
and it is deliberate — it belongs to the open product decision on the client-side
tool loop.

### Python, all seven packages under `agents/`

crypto 65 · config 63 · sandbox 107 · manager 183 · host 281 · runtime 964 ·
executor 234 = **1897 passed, 1 failed**. The failure is
`test_regenerate.py::test_four_retries_replay_the_question_once`, pre-existing on
the branch and reproducible with no upstream code present.

### Flutter, with both baselines measured

| tree | result |
| --- | --- |
| upstream `master` alone | 1553 passed, 272 skipped, **0 failed** |
| `agents` branch alone | 1441 passed, 3 skipped, 8 failed |
| **merged** | 2885 passed, 275 skipped, **64 failed** |

Upstream's suite is green on its own, so every merged failure is either ours from
before or caused by a merge decision. The 64 sort into four groups:

**a. The tool-loop decision — 21 failures, 5 files.** `tool_call_handler_deferred_action`
(11), `tool_call_reasoning_lift` (4), `tool_call_handler_fact_check` (4),
`tool_call_handler_safety_limit` (1, does not compile), `tool_call_handler_stub` (1).
These describe upstream's client-side tool loop, which the Agents stub replaced
because tools run on the host. They stay red until the product question is
answered: does a chuk_chat user with no host paired get no client-side tool loop?

**b. Features the mobile rebuild dropped — 3 failures.**
`agents_thread_view_test` fails on the key `host-run-typing`: the host typing
bubble is one of the behaviours named in the MERGE NOTE at the top of
`chat_ui_mobile.dart`. The test is right and the code is missing, not the reverse.

**c. Test expectations that now describe the other side — roughly 15 failures.**
`messenger_shell_test` looks for the text "Chuk Chat" and finds none, because
`brand_wordmark.dart` was restored to upstream's SVG wordmark. `settings_page_test`
asserts the hub lists only "the areas Agents keeps" and now finds upstream's
"Sandboxes" row as well. These are tests written against the Agents-only tree
meeting the merged tree; the merged behaviour is intended, so the tests move.

**d. Layout and golden comparisons — 25 failures.** `every_screen_layout_test`
(15), `document_chart_golden_test` (4), `mobile_preview_test` (4),
`model_selector_design_test` (2). Two UI histories met in one tree, so pixel
baselines have to be re-taken and read once by a human.

### What must be decided before stage 7

1. The tool loop (group a) — see the bead. Either the fold comes back behind a
   flag, or the four upstream test files go.
2. The mobile features in the MERGE NOTE (group b), the host typing bubble first.
3. Chats: the facade reads chuk_chat chats from `encrypted_chats` and writes them
   through the Agents store into `cowork_chats`. Cloud copies of edited chats land
   in the wrong table.
4. The offline queue: messages enqueue into `AgentsTaskOutbox` and drain from
   `OfflineQueueService`.
5. Beads: the `cowork` Dolt database has to be imported into `chuk_chat`, or 241
   issue ids go dark in the merged checkout.
