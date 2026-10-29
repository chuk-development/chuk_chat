# Settings order: important first, the rest under "Advanced"

Status: 2026-10-29, bead `chuk_chat-pjom`. Owner: "only the important things a
user normally sets are at the top, everything irrelevant goes somewhere else."
Users are not technical. Basis: `docs/agents/DESIGN_SCHEME.md` 2.0 ("weniger
ist besser") and the Grok review (their bot profile: 3 rows + 1 switch).

## Rule

- Each settings screen shows only what a normal user changes.
- Everything else goes into ONE fold per screen: "Advanced" / "Erweitert"
  (`ExpressiveAdvancedSection`, `lib/widgets/expressive_settings.dart`,
  l10n key `settingsAdvanced`). It is closed when the screen opens. One tap
  opens it in place, with the old section headers inside.
- Nothing is deleted or renamed. Pages, storage keys, row keys and tour
  anchors stay the same.
- Desktop rail (`lib/pages/desktop_settings_modal.dart`): the same split. The
  fold is a rail row with a chevron. A search opens it (a search for
  "advanced"/"erweitert" lists all of it). The modal opens with the fold open
  when `initialSectionId` names a page inside it.
- Tour anchors (model, pricing, AI identity, assistant) stay at the top, so
  the onboarding tour always finds its targets.

Frequency: H = a normal user touches it, M = sometimes, L = rarely / technical.

## App settings (phone `settings_page.dart`, desktop modal)

| Entry | What it does | Freq | Place |
|---|---|---|---|
| Account | Name, mail, password, sign out, delete | H | top |
| Pricing Plans | Plan, credits, payment | H | top |
| Model Selection | Default model for chats (and agents) | H | top |
| AI Identity & Memory | What the AI knows about you, memory | M | top (tour target) |
| Connectors | Connect apps (Gmail, Notion, ...) | M | top |
| Assistant (Android) | Use chuk as phone assistant | M | top (tour target) |
| Theme Settings | Look: dark mode, preset, accent | H | top |
| Customization | Language, notifications, text size | H | top |
| About | Version, licences | M | bottom, outside the fold |
| Tool Calling | Which tools the AI may call | L | Advanced / Tools & skills |
| Skills | Built-in procedures | L | Advanced / Tools & skills |
| Voice calls (flag) | Phone permissions for calls | L | Advanced / Tools & skills |
| GitHub | Token for the GitHub connector | L | Advanced / Tools & skills |
| here.now, Embedding, API Keys, Mailbox, Automations, Host skills (Agents build) | Host-wide agent things | L | Advanced / Agents |
| Export chats (dev) | JSON backup | L | Advanced / Data & Privacy |
| Show onboarding again (chuk build) | Replay the tour | L | Advanced / System |
| Developer options (dev) | Debug | L | unchanged (dev only) |
| Sign out | | H | unchanged, at the end |

## Customization (`customization_page.dart`)

| Entry | Freq | Place |
|---|---|---|
| Language | H | top |
| Notifications: answer preview | M | top |
| Chat text size | H | top |
| Voice: auto-send transcription | L | Advanced |
| Message display: reasoning, model info, TPS | L | Advanced |
| Chat font family | L | Advanced (also on Theme) |
| UI scale | L | Advanced |
| AI context: images, reasoning, tool results | L | Advanced |
| Full log (Agents build) | L | Advanced |
| Downloads folder | L | Advanced |
| Chat titles + title prompt | L | Advanced |

## Theme (`theme_page.dart`)

| Entry | Freq | Place |
|---|---|---|
| Preset pack | H | top |
| Dark mode, Material You | H | top |
| Accent colour | M | top |
| Icon/foreground colour, background colour | L | Advanced |
| Contrast | L | Advanced |
| Interface font, chat font | L | Advanced |

## Agent settings (`mobile_agents_settings_page.dart`, phone page and desktop pane)

Top: face, name, role, "Chat" button, then one group of 3-4 rows:

| Entry | Freq | Place |
|---|---|---|
| Profile & preferences (name, face, role, brief) | H | top |
| Model | H | top |
| Permissions (what it may do, budget) | H | top |
| Documents & pages (when the shell offers it) | M | top |
| Skills, Connected apps, API keys, Schedules | L | Advanced / What it can do |
| Mail | L | Advanced / Channels |
| Runs on the host, Host & activity, Open screen | L | Advanced / Its computer |
| Show thinking, Show work, Export conversation | L | Advanced / Conversation |
| Control rooms, Account & app settings | L | Advanced / App |
| Hide, Remove agent | L | Advanced / Danger, last |

## Left as they are

- Account page (Profile, Security, Chat recovery, Danger zone): already short
  and all of it is account.
- Agent profile editor (picture, figure, name, role, brief): one form, five
  fields, one Save.
- Agent model page, agent permissions page: one topic each.
- Connectors page: owned by another workstream; linked as it is.
