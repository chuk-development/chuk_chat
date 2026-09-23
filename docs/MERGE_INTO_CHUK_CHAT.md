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
