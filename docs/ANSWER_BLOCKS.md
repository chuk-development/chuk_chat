# Answer blocks

The `:::` blocks are the answer UI the model uses all the time. OpenUI
(`docs/OPENUI.md`) is only for what they cannot do: forms, tabs, editable
tables. In an audit of 325 real answers (2026-11-01), the model wrote `:::`
blocks often and OpenUI never.

| Part | Where |
|---|---|
| Parser, pure Dart | `lib/utils/answer_blocks_parser.dart` |
| Widgets | `lib/widgets/answer_blocks.dart`, `visual_answer_blocks.dart`, `visual_answer_blocks_more.dart` |
| Prompt | `ToolPromptBuilder._answerFormatSection` (budget in `answer_blocks_parser_test.dart`) |
| Real-case tests | `test/utils/answer_blocks_real_cases_test.dart` |

## See real answers

`scripts/answer_replay.sh [--light] [--width 430] <messages.json> <out dir>`
draws each message through the real `MessageBubble` under its own Xvfb and
writes one PNG per message. It needs no login, it has its own
`XDG_DATA_HOME`, and it does not touch the owner's screen.

The JSON is a list of `{"id", "text"}`. Real chats are in
`~/.local/share/dev.chuk.chat/chat_cache.db`, table `chat_cache`. `payload` is
base64 of the frame in `docs/CHAT_PAYLOAD_FORMAT.md`. Keep extracts in
`_scratch/`: they are private.

## Rules the parser forgives

Models make these mistakes, so the parser repairs them. The prompt also tells
the model not to make them.

- `::` closes a block. Before this, the rest of the answer became cards.
- `**` in a card title is removed.
- A short plain line after card keys starts a new card, without `--`.
- A tile line with no `|` is the subline of the tile above.
- A first `::: ask` line that ends in `?` is the heading, not a chip.
- `::: warning`, `::: note` and similar draw as alerts.

## How cards draw

- No image and no price on any card: a stacked list with the full text. A
  carousel would hide all cards but one and cut the text.
- Otherwise a carousel. A mouse can drag it and it has previous and next
  buttons, because a `PageView` takes only touch drags by default.
- `::: bars` draws bars only if `BarsSpec.isComparable`. Prose values draw as
  fact rows.

## Card images

`_CardImage` tries, in this order: `image:`, `thumb:`, the `og:image` of the
`url:` page, the site logo. The model gets `image:` and `thumb:` from
`web_search type:"images"` (Brave): `thumbnail_url` is hosted by Brave, so it
loads when a shop blocks a direct fetch. `og:image` is not first because a
`url:` can be a search or category page, and that page gives a site banner.

Photos of priced items use `BoxFit.contain` so that the product is not cut.
A price per unit (`248 CHF / Nacht`) is a stay, so it fills the frame.
