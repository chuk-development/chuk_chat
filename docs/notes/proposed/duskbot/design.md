# DuskBot: visual design and UX analysis

Read-only review of the shallow clone at `/home/user/git/chuk_chat/_scratch/duskbot` (commit e0c03fa).
License is PolyForm Noncommercial: ideas and patterns only, no code, copy or art taken over.

Note on lineage: the app's own docs say its look is modelled on xAI's Grok ("Grok's panes", "grok's bubbles",
skin `grok`). Do not borrow that look for Chuk Chat either.

## 1. Layout, navigation, headers

**Desktop (Electron, `electron/`, `src/components/`)**

- Far left: a thin **places rail** (`src/components/PlacesRail.tsx`, 36px wide, 24px tiles, rounded squares).
  It shows only when the person has two or more places (computers / cloud boxes). Tile count capped at 8, then a
  "more" list.
- Left: **sidebar** (`src/components/Sidebar.tsx`, `SidebarSections.tsx`). Default 288px, max 400px, drag handle
  (`SidebarResizeHandle.tsx`). Below 160px the column collapses to avatars only. Sections are collapsible,
  reorderable by drag or Alt+Up/Down, and remember state (`src/lib/sidebar-preferences.ts`).
- Centre: chat column. Width presets `standard | wide | full` (`src/lib/chat-width.ts`), column max 60rem.
  Floating **head pill** with bot name, top centre (`ChatHeadPill.tsx`). Composer pinned at the bottom.
- Right: **bot panel** (`src/components/bot-panel/PanelShell.tsx`), opened per bot. Three tabs
  `details | computer | advanced` (`page-registry.ts`, `PANEL_TABS`), plus a page stack with a back label
  ("Back to Details"). Rows that open a full settings page deep-link via `SECTION_TARGET` map.
- Sidebar footer: account button plus a "Connect apps" pill that shows four app logos (`SidebarConnectApps.tsx`).
- Minimum window 768x520. Below 984px the panel overlays the chat (the audit flagged it, finding 4).

**Mobile (`src/mobile/`)**

- No bottom tab bar (grep for tabbar found nothing). Home is one list: pinned section, folders (`home-folders.ts`),
  chat rows, and a horizontal row of 84px bot "hold" tiles (`HomeScreen.tsx`).
- Push navigation via `NavStack.tsx` (page stack with slide paths). Secondary surfaces are bottom sheets
  (`Sheet.tsx`, `SheetHost.tsx`), with `PullToRefresh.tsx`.
- Long-press opens a menu (`ContextMenu.tsx`, `native-menu.ts`), with a native-menu hook on iOS/Android.
- Touch rules in CSS: `@custom-variant touch` keeps hover-revealed controls visible on touch (`src/styles.css`
  top), and the `active` variant replaces a pressed fill with scale/ripple (`src/mobile/press.ts`).

**Model:** desktop = three columns (places | conversations | chat | panel). Mobile = one list that pushes into a
chat and slides in sheets. Same objects, different containers.

## 2. Design system

**Tokens.** All colour, radius, font and shadow tokens are CSS custom properties in `src/styles.css`, declared in
`@theme` (Tailwind v4) and redefined per skin under `[data-skin="…"]` selectors. There are 13 skins
(`src/lib/skins.ts`): midnight (default dark), atelier, foundry, lagoon, graphite, linen, dusk, daylight, meadow,
pop, grok, grok-dark, halloween. `system` follows OS light/dark and maps to `grok` / `grok-dark`.

- Surface ladder (the core idea): `--color-app`, `--color-panel`, `--color-raised`, `--color-raised-hover`,
  `--color-composer`, `--color-card`, `--color-menu`, `--color-control`, `--color-inset`, `--color-hairline`,
  `--color-edge`. Borders are rare; separation is tonal.
- Ink: `--color-ink`, `--color-ink-secondary`, `--color-ink-tertiary` (each tuned to clear 4.5:1 on every surface).
- Accent `--color-accent` (#1084fe default), success, danger, warning, focus ring grey (3:1, never the accent).
- Radii: `--radius-xs` 2px through `--radius-4xl` 18px on the light skins. `--radius-menu` 14px. Bubbles 18px,
  composer 24px, tool rows `rounded-xl` (12px), buttons full pill.
- Shadows: almost none. `--shadow-float: 0 0 #0000` on the dark skins, and a rule that stray shadows are a bug.
- Fonts: Geist Variable and Geist Mono (`src/font-faces.css`), with Inter bundled too. Sizes are hard-coded
  per component in Tailwind arbitrary values: bubbles 15/20, composer 14/20, tool rows 13px, meta labels 12px.
- Chat width and bubble max are tokens (`--chat-bubble-max`, `--chat-column-max`) with three presets.

**Motion.** `src/mobile/motion.ts` and `src/lib/motion-presets.ts`: durations fast 160 / base 220 / slow 420 /
long 600 ms; eases `out`, `pop`, `release`, `menuIn`; four springs. CSS keyframes in `styles.css`
(`--animate-*`). Stated ceiling: 300 ms for UI, onboarding may run longer. Press feedback = scale .96 in 110 ms
(`feel.press`). `prefers-reduced-motion` honoured (`sheet-close-reduced.dom.test.ts`).

**Icons.** `lucide-react` (package.json), plus own set in `src/icons/` (`drawn.tsx`, `glyph.tsx`, `gravity.ts`,
with a gravity-ui license file) and pixel art: `PixelIcon.tsx`, `PlaceArt.tsx`, mascot engine (`mascot-engine.ts`).
Bots are pixel mascots with a colour (`MausAvatar`), not photos.

**Enforcement (what is real).**

- `pnpm lint` = `oxlint --deny-warnings` (`.oxlintrc.json`, few overrides).
- `pnpm check:contrast` = `scripts/check-skin-contrast.mjs`, measures the rendered text/surface pairs.
- `pnpm ui:baseline` = `scripts/testing/visual-baseline.ts`, screenshots of key surfaces in light and dark, at
  desktop and min size, compared with the approved set in `scripts/testing/visual-baseline/` (208 PNGs).
- `docs/ui-audit-2026-11-14.md`: a full audit of about 300 screenshots against written brand rules, 21 ranked
  findings with status (borderless tonal contrast, no stray shadows, one spacing scale, sentence case, "dusk bot"
  lowercase, short copy).
- Shared UI kit `src/components/ui/`: `GrokDialog.tsx`, `SegmentedTabs.tsx`, `Segmented.tsx`, `SelectPill.tsx`,
  `Toggle.tsx`, `Notice.tsx`, `Toast.tsx`, `ModalLayer.tsx`, `SettingGlyph.tsx`, `SheetMotion.tsx`.
- Unit tests that assert class strings to police style, e.g. `ModelPicker.simple.test.ts` forbids `border`,
  `shadow-2xl`, `rounded-2xl`; `GoalRunCard.test.ts` forbids accent/shadow/border; `SidebarSectionHeader.test.ts`
  pins exact Tailwind classes; `touch-actions.test.ts` enforces the `touch:` rule; `file-size-ratchet.test.ts`.
- Assessment: strong on discipline (baseline + contrast + ui audit), weaker on tokens as a single source. No Figma
  or JSON token export; colours live only in CSS, and many one-off arbitrary values (`text-[13px]`, `rounded-[18px]`)
  sit in components. Class-string tests make refactors brittle.

## 3. Messages and threads

- **Bubbles** (`src/components/chat-bubble.ts`): bot = 6% ink wash with faint top gloss (`chat-bubble-bot`), user =
  `--color-bubble-user` (#5a5a5a on midnight) with `--color-bubble-user-ink`. Optional bot colour on user bubbles
  (Settings > General > Accent: "bot" or "neutral", `AccentRow` in `SettingsPanes.tsx`).
- **Grouping**: consecutive messages from the same speaker pull up 12px (`SIMPLE_STACKED = "-mt-3"`) and get
  join flags above/below (`BubbleJoin`). Rows are 16px apart otherwise. Bubble corners are the only "tail" cue.
- **Emoji-only messages**: 1-3 emoji drawn at 40px with no bubble (`EMOJI_ONLY_TEXT`, `emojiOnly`).
- **Cards in the transcript** (the most distinctive part; see `visual-baseline/cards-settled-desktop-grok.png`):
  one family for questions (`AskCard.tsx`), approvals (`ApprovalCard.tsx`), secrets, browser sign-in, connectors
  (`ConnectorCard.tsx`), tables. Anatomy: small glyph chip + tool name, title, body, action row
  (Skip / I'm done / Take over). Radius 12-14px, no border, tonal fill on the thread.
- **Settled state**: a card that has been answered collapses into a one-line receipt row: "Secrets · Saved · Stripe
  API key", "Browser · Done · Sign in to ...", "Secrets · Cancelled". The same row style covers "replaced by a
  newer request". Visible in `visual-baseline/surface-chat-typing-desktop-grok.png`.
- **Tool calls** (`src/components/ToolActivity.tsx`): a `<details>` row, collapsed by default, `min-h-8`, status
  glyph (dots while running, check, X), label from `toolStepLabel`, optional place icon, and status words
  ("Running", "Completed", "Failed", "Unverified"). Opened, it shows Input and Output as `bg-inset` mono blocks with
  a max height and scroll. Clipped output loads the full text on demand.
- **Sources / links**: web addresses get a "link pill" on hover (`.link-pill` in `styles.css`): text colour kept,
  a soft accent wash behind it, side shadows instead of padding so the caret mirror stays aligned.
- **Files**: attachments as a 28px file chip under the message, with a 24px round preview action; a gallery
  component for several images (`AttachmentGallery.tsx`), file-kind glyphs (`FileKindIcon.tsx`).
- **Composer** (`src/components/Composer.tsx`, `ComposerSendButton.tsx`): one pill, `rounded-[24px]`, minimum 48px,
  text area grows to `max-h-[9rem]` (144px), then scrolls. Left: plus menu (32px round ghost). Right: mic as a neutral
  32px circle, Send as the single filled button. Stop replaces Send while a turn runs. Approval dock sits above the
  pill (`data-approval-dock`), queued messages and failed sends have their own strips.
- Head pill and rows fade under each other: a short top fade under the head pill (audit finding 11).

## 4. Settings and connectors

**Settings modal** (`src/components/SettingsModal.tsx`, `src/lib/open-settings.ts`): 11 panes in a left rail grouped
into three labelled groups (`RAIL_GROUPS`):

- You: **General**, **Voice**.
- Your bots: **Computer**, **Texting** (phone, only when the phone app is enabled), **Permissions**, **Vault**,
  **Models**, **Bots** (hosts the per-bot page a bot's panel links to; not on the rail).
- This app: **Usage**, **Updates**, **Advanced** (an index of pages: Apps, Team, Data).

General pane rows (`AppSettingsRows.tsx`, `SettingsPanes.tsx`): account rows, accent (bot/neutral), default effort
for new bots, talking style, quick updates, language, send key (Enter / Cmd+Enter), bot order in sidebar (recent /
custom), follow-up while a bot works (steer / queue), experimental skill authoring, import from other apps.
Advanced pages: Apps (apps, skills, builder, experimental), Team (organisation, people), Data (data, backups).

Count: about 9 general rows, 11 rail panes, 3 advanced pages. Not "few", but each row is one sentence and most
panes are one screen. Simple mode hides more (`SIMPLE_PAGES` in `page-registry.ts`).

**Connectors, two levels:**

1. **Global, per account** (`src/components/connect-apps/`, `shared/app-tokens.ts`): one "Connect apps" window.
   12 paste-token apps (GitHub, Notion, Linear, Airtable, Todoist, Trello, ClickUp, HubSpot, Jira, Shopify, Stripe,
   Cloudflare), plus native device sign-ins from `shared/native-connectors.json`. Each account row shows who it
   signed in as, when, and "needs reconnect". Reconnect uses `replaces`, so every bot keeps its access (the
   account row keeps its MCP server name). Tokens never reach the window.
2. **Per bot** (`src/components/bot-settings/ConnectorGrantRows.tsx`, `ToolSelectionCard.tsx`): each bot's grant
   reads as a short phrase: "All tools", "No tools", "N tools", or "Custom" when a package sets it.
   Chat cards for a connector show state with one button ("Connected · Continuing" + Manage).

## 5. Groups, rooms, multi-agent

- A **room** is one shared transcript with several bots and people (`GroupView.tsx`, `RoomHeader.tsx`,
  `src/components/room-panel/`). Created from **Sidebar > New channel** (`SidebarNewRoomPanel.tsx`, `NewRoomPanel`):
  name, optional context (a department), pick bots from a list.
- Sidebar row avatar: `GroupAvatar.tsx` shows the person's face or initials beside bot avatars.
- Speaker choice: a router line "Picked by {name} · {percent}%" (`room.routedBy`), so the person sees why a bot spoke.
- @mentions: an `@` list; same-name bots trigger a disambiguation message ("Pick the one you mean from the @ list").
  Per-bot queue runs one turn at a time ("runs one at a time; it starts when that finishes").
- Room transcript draws bubbles only: stops and settled cards leave no technical rows (`GroupView.tsx` ~line 368).
- Pinned **bulletin** at the top (`RoomBulletin.tsx`), working lines while bots run (`RoomWorkingLines.tsx`),
  and a room panel with tabs Details / Computer / Advanced, the same three as a bot panel (`RoomPanel.tsx`).
- Departments (sidebar sections holding bots) are the team-level grouping; they can be shared as one file
  (`docs/team-sharing.md`).

## 6. Ten design ideas to take (ranked)

1. **One tonal surface ladder, one radius scale, no stray shadows, enforced by a screenshot baseline.**
   Evidence: `src/styles.css` (surface tokens, radius scale), `docs/ui-audit-2026-11-14.md` (findings 1, 10),
   `scripts/testing/visual-baseline/`. In Chuk Chat: name the 8-10 surface tokens in one theme file, and gate PRs
   on a set of approved screenshots in light and dark at phone and desktop width.

2. **Answered cards collapse to a one-line receipt.** Evidence: `visual-baseline/cards-settled-desktop-grok.png`,
   `surface-chat-typing-desktop-grok.png`, the settled rows in `src/components/AskCard.tsx`. In Chuk Chat: an agent
   question or approval answered in the Agents transcript becomes "Question · Answered · Monday" in one row.

3. **Tool calls as collapsed rows with status words, expand for input and output.** Evidence:
   `src/components/ToolActivity.tsx` (status glyph, "Running / Completed / Failed / Unverified", inset mono
   blocks, lazy full output). In Chuk Chat: Agents steps show as one row each in the thread; the host's command and
   output sit behind a tap.

4. **Stacked bubbles: same speaker pulls in 12px, one join flag per side.** Evidence:
   `src/components/chat-bubble.ts` (`SIMPLE_STACKED`, `BubbleJoin`). In Chuk Chat: a run of agent messages reads
   as one block with the name shown once.

5. **Composer as one pill: 48px minimum, grows to 144px then scrolls, one filled button (Send), mic as a neutral
   circle, Stop replaces Send while running.** Evidence: `src/components/Composer.tsx` (lines ~989-1121),
   `ComposerSendButton.tsx`. In Chuk Chat: the Agents composer shows Stop in the Send place during a run, the
   approval dock sits above the pill.

6. **Right panel = three tabs plus a page stack with a back label, and every settings row deep-links to a page.**
   Evidence: `src/components/bot-panel/page-registry.ts` (`PANEL_TABS`, `SECTION_TARGET`, `resolveTarget`),
   `PanelShell.tsx`. In Chuk Chat: the agent's right sidebar uses the same Details / Computer / Advanced split, and
   "Routines" in the details tab opens the routine page with a back link.

7. **Sidebar rows show the live step under the name, and the column can shrink to avatars.** Evidence:
   `src/components/SidebarWorkingStep.tsx`, `sidebar-preview.ts`, `SidebarResizeHandle.tsx` (`AVATARS_BELOW = 160`).
   In Chuk Chat: each agent row shows "Running: git status" under its name; drag the edge narrower to get avatars.

8. **Connectors split: accounts connect once globally, each agent gets a one-phrase grant.** Evidence:
   `shared/app-tokens.ts` (`needsReconnect`, `replaces` keeps the server name), `connect-apps/`,
   `bot-settings/ConnectorGrantRows.tsx` ("All tools / No tools / N tools"). In Chuk Chat: connectors page once for
   the account, and each agent's detail shows "All connectors" or "3 connectors" with a Change link.

9. **Settings as a grouped rail (You / Your agents / This app) with an index page for the rest.** Evidence:
   `src/components/SettingsModal.tsx` (`RAIL_GROUPS`, `RAIL_GLYPH`), `src/lib/open-settings.ts` (`ADVANCED_PAGES`),
   `SettingsPanes.tsx` (`AdvancedIndex`). In Chuk Chat: three rail groups, and "Everything else" holds the rarely
   used pages (data export, team, experiments).

10. **Motion as named tokens with a press feel and a reduced-motion path.** Evidence: `src/mobile/motion.ts`
    (`dur`, `ease`, `spring`, `feel.press` scale .96 in 110 ms), `src/styles.css` `--animate-*`, the 300 ms ceiling
    comment. In Chuk Chat: a single `motion` file for Flutter (durations 160/220/420, one curve, press scale 0.96),
    and no motion longer than 300 ms outside first-run.

Honourable mention (not in the top 10): the pixel mascot per bot with a colour toggle (`src/components/Avatar.tsx`,
`AccentRow`). It gives strong identity but is a brand decision.

## Gaps and caveats

- Visual check was limited to three of the 208 baseline PNGs: a desktop thread with settled receipts and an open
  secrets card (the `cards-*` / `surface-chat-typing-*` family, grok skin), the "Meet dusk bot" welcome
  (`surface-onboarding-account-desktop*`), and the min-window sidebar with the first-question card
  (`surface-chat-empty-min*`). The rest is from code and the audit doc.
  Not every skin or every screen was viewed.
- No design file or token JSON exists in the repo; tokens are read from CSS only.
- Desktop and mobile were judged from code and the audit doc, not run. Nothing was built or launched (read only).
