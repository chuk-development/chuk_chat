# Pages

Status: 2026-10-29. Owner request: rename "Artifacts" to "Pages", and let
every agent keep its own pages.

## 1. What a page is

A page is a document that an assistant or an agent makes and keeps up to
date. The user reads it in the app. A page has these fields:

| Field | Meaning |
|---|---|
| `id` | A short name. It is unique for one agent. |
| `title` | The name that the user sees. |
| `kind` | The format: `markdown` or `html`. |
| `text` | The content of the page. |
| `version` | Starts at 1. Each write adds 1. |

The app also shows two other document kinds in the Pages list: `table` and
`bar_chart`. They use the same store and the same versions.

## 2. Names: what the user sees and what the code uses

The user sees "Pages" ("Seiten", "Páginas"). The code keeps the old names.
Do not rename them: stored data, wire fields and old clients use them.

| The user sees | Internal name | Where |
|---|---|---|
| Pages (chat build) | artifact, `ArtifactDocument`, `artifact_manager` tool, `<artifact>` tag | `lib/services/artifact_*`, `lib/widgets/artifact_panel.dart` |
| Pages switch in settings | `FEATURE_ARTIFACTS`, `kFeatureArtifacts`, l10n key `toolArtifacts` | `lib/platform_config.dart`, `lib/l10n/` |
| Pages tab in Media (chat build) | `_MediaFilter.artifacts` | `lib/pages/media_manager_page.dart` |
| Pages of an agent | `chat_document` tool, table `chat_documents`, frames `documents_list` / `document_read`, mime `application/vnd.cowork.document+json` | `agents/runtime/src/chuk_agents_runtime/chat_documents.py` |
| Pages tab in Media (Agents build) | `MediaKind.page` | `lib/services/agents/media_index.dart`, `lib/platform_specific/mobile/mobile_media_page.dart` |

The model sees the old tool names. The tool descriptions tell the model to
say "page" when it talks to the user.

## 3. An agent keeps its own pages

The agent uses the `chat_document` tool. There is no second tool. Before this
change the tool already had id, title, kind, text, version and
`expected_version`. The change adds one kind: `html`.

- `action=list` gives `id`, `title`, `kind`, `version` of each page.
- `action=read` gives the whole page.
- `action=write` makes a page, or replaces the text of a page.
- To change a page, the agent reads it first. Then it writes the new text
  with `expected_version` set to the version that it read. When the version
  is not the same, the host saves nothing and tells the agent to read again.
- When `kind` is not given on an update, the page keeps its kind.
- A page is at most 256 KiB.
- An `html` page must have text. An `html` page takes no `rows` or `columns`.

The store is keyed by `session_key`. A `session_key` is an agent id
(docs/WIRE_CONTRACT.md, "One sandbox per agent"). Thus each agent has its own
pages, and an agent cannot see the pages of a different agent.

For `html`, the agent writes one complete document with inline CSS and JS.
The app shows it in a sandbox. The page cannot read the workspace of the
agent.

## 4. How a page gets to the app

There is no new frame. The host uses the frames that it already has:

1. Each write sends a `file` event. The event has the whole page in its
   `document` field. The file name ends in `.html` for an `html` page and in
   `.md` for a `markdown` page.
2. The app keeps the event as a file block in the thread, as before. The
   encrypted chat sync takes the block to all devices of the user.
3. The app can ask for the list (`documents_list`) or for one page
   (`document_read`) at any time.

## 5. How the app shows a page

- `markdown`: the app's own markdown renderer (`ChatDocumentView`).
- `html`: `HtmlArtifactView`, the same view that the chat build uses for HTML
  artifacts. On Android, iOS, macOS and Windows it is a web view with
  JavaScript on, and file access, new windows and navigation off. A link
  opens in the system browser. On Linux the default build has no web view.
  There the user gets an "open in browser" action.
- In the thread, an `html` page is a short row. A tap on the row opens the
  page. The thread never shows HTML source.
- Media > Pages (phone, Agents build) shows one row for each page of each
  agent. Many versions of one page are one row; the newest version wins. A
  tap opens the newest version from the thread on this device.

## 6. Old clients

An old app does not know the kind `html`. It shows the text of the page as
markdown, so the user sees the HTML source. Nothing is lost, and an update of
the app shows the page correctly. No data migration is necessary.

## 7. Not in this version

- The agent cannot delete a page. A delete needs a new action and a new
  frame.
- The chat build (no Agents) keeps its own pages in `artifacts`. The Agents
  Media tab does not show them.
- here.now (`lib/services/herenow/`) publishes a page to a public URL. It does
  not yet take a page from the `chat_document` store.

## 8. Tests

- `agents/runtime/tests/test_chat_documents.py`, section "pages".
- `agents/executor/tests/test_pages.py`: write, list and read over the
  encrypted channel, and two agents that do not share pages.
- `test/services/media_index_test.dart`, group "pages".
- `test/platform_specific/mobile/mobile_media_page_test.dart`.
- `test/widgets/chat_document_view_html_test.dart`.
