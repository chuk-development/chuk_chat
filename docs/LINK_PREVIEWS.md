# Link previews

Links in a message look and behave like in Grok Bot: no bare URL and no card
under the message. The card only floats on demand.

## How a link looks

- The link reads as its short name: the markdown link text (`[Inflect Mini
  v3](https://…)`). A bare URL, or a link whose text is its own address,
  reads as `host/path` (`example.com/voice/overview`).
- In front of it sits the site icon of the target page, one text line high
  (the font size) and centred on the line. Until the icon is loaded, and for
  sites with none, a neutral link glyph keeps the place, so the text does not
  move. The icon starts loading when the message is drawn.
- Only the name is underlined, not the icon.

## The card

- **Desktop:** the mouse rests on the link for 400 ms, the card floats above
  the link (below when there is no room). The pointer can move into the card;
  leaving both closes it.
- **Touch:** a long press (420 ms, before text selection starts at 500 ms)
  shows the same card; a tap anywhere else closes it. A short tap opens the
  link as before (with the "Open Link" question).
- About 300 px wide, theme colours, 1 px `outlineVariant` border, corner 16,
  small neutral shadow, no glow.
- Without og:image: `Title · Site` (bold, one line), description (3 lines,
  grey), footer with icon, `host/path` and an open arrow.
- With og:image: the picture at full card width on top, then the title
  (2 lines), description and footer. GitHub has no special path: its
  og:image is GitHub's own repo/PR/issue card.

## Privacy

The app never contacts the linked site. api_server fetches the page
(`GET /v1/link_preview`) and proxies the picture and the icon
(`GET /v1/link_preview/image`). Only the URL leaves the device, not the
message. Server details, SSRF rules and limits: `api_server/CLAUDE.md`,
"Other Endpoints".

## Cache

Memory, then SQLite `kv_cache` (key `link_preview:v1:<url>`, card 3 days,
"no card" 12 hours), picture and icon bytes in `ImageDiskCache` (key
`link_preview/<url>`). A network error is not stored; the URL is only skipped
for 5 minutes in memory. No data means no card, never an error.

## Code

| What | Where |
|---|---|
| Fetch, cache, `shortUrlLabel`, `linkTextIsUrl` | `lib/services/link_preview_service.dart` |
| `LinkFavicon`, `LinkPreviewCard`, `LinkPreviewHover`, `linkPreviewRecognizer` | `lib/widgets/link_preview_card.dart` |
| Hook (the only one) | `lib/widgets/markdown_message.dart`, `AccentLinkNode.build()` with `hoverContext` |
| Tests | `test/services/link_preview_service_test.dart`, `test/widgets/link_preview_card_test.dart` (incl. icon centre on the line), goldens `test/widgets/link_preview_card_golden_test.dart` (real Roboto, measures again) |

Keep the hook when the markdown changes. If `/tmp` is full, run the tests
with `TMPDIR=$PWD/_scratch/tmp`.
