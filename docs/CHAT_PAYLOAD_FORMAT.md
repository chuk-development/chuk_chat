# Chat payload format (v3)

How a chat is stored in `encrypted_chats.encrypted_payload` and in the SQLite
cache, since 2026-09-24. Code: `lib/services/chat_payload_codec.dart`
(the JSON), `lib/services/payload_compression.dart` (the frame),
`lib/services/encryption_service.dart` (the envelope),
`lib/services/chat_payload_migration_service.dart` (the one-time rewrite).

## Layers

```
messages (ChatMessage.toJson)            in memory, unchanged
  -> payload JSON v3                     chat_payload_codec.dart
  -> frame: 0x00, codec, length, data    payload_compression.dart
  -> AES-256-GCM, envelope {"v":"2"}     encryption_service.dart (cloud only)
```

The SQLite cache stores the frame (deflate) without encryption. The web cache
(SharedPreferences) stores the v3 JSON as text.

## Payload JSON

| v | Written by | Shape |
|---|---|---|
| 1 | very old apps | `{"messages":[...]}`, legacy field names |
| 2 | apps before 2026-09-24, the Agents store | `{"v":2,"messages":[...]}`; nested fields are JSON in a string |
| 3 | this app | `{"v":3,"messages":[...]}`; no duplicates, nested fields as real JSON |

v3 changes per message (the reader turns it back into exactly the v2 message):

- `toolCalls`, `contentBlocks`, `images`, `imageMetas`, `attachments`,
  `attachedFilesJson`, `variants` are real JSON, when
  `jsonEncode(jsonDecode(s)) == s`. Any other string stays a string.
- A tool call inside a `toolCalls` content block that is byte-identical to an
  entry of `toolCalls` is stored as that entry's index. In v2 each call and
  its result was stored twice (35 % of all bytes).
- `roundThinking` that repeats reasoning text is a reference: an int (index
  of the reasoning block with that exact text), `[start, length]` (slice of
  `reasoning`) or `[start, length, 1]` (slice of the joined reasoning blocks).
- `_ref` (bit mask) says which references a message uses: 1 = tool-call
  indexes, 2 = roundThinking references. Without the bit nothing is resolved.

The encoder decodes every message again and falls back to the plain v2 form of
that message if it does not come back byte-identical. A payload with a version
above 3 is refused (`UnsupportedError`), never read as v1.

## Frame and codec

`0x00 | codec | uint32 LE uncompressed length | data`. Codec 1 = raw deflate,
2 = bzip2, both from `package:archive` (pure Dart, so the same code on
Android, iOS, Linux, Windows, macOS and web). The reader also takes a gzip
blob (`1f 8b`, the cache before v3) and plain UTF-8 JSON.

- Cloud: the smaller of bzip2 and deflate-9. Every bzip2 frame is decoded
  again before it is used. On the web, above 128 KB only deflate (no isolate
  there, bzip2 is slow in JavaScript).
- Cache: deflate-6. A chat opens from the cache; bzip2 decodes several times
  slower for about 6 % less. Every cache row is framed, even a short one (see
  "Old clients").

Why not brotli, zstd or LZMA (measured on the v3 JSON of 939 real chats,
38.8 MB): brotli-11 8.6 MB, xz-9e 9.4 MB, zstd-19 9.6 MB, bzip2 10.2 MB,
deflate-9 10.9 MB, min(bzip2, deflate) about 10.1 MB. No brotli or zstd
encoder runs on every platform including the web (the pure-Dart zstd in
`libcompress` reached only 20 % of raw). The pure-Dart `lzma` package (2021)
allocates about 200 MB per encode for its fixed 8 MB dictionary and needs
11 s for 13 MB. After the v3 de-duplication the codec gap is small: most of
the saving is the format.

## Envelope

`{"v":"2","kv":<key version>,"nonce","ciphertext","mac"}`: the ciphertext is
the frame. Everything else (titles, prompts, images) keeps `{"v":"1"}` with
UTF-8 cleartext. The new reader accepts both for every decrypt call.

## Measured (939 real chats, `test/manual/chat_payload_v3_real_data_test.dart`)

| | avg | p90 | max | total |
|---|---|---|---|---|
| plaintext v2 JSON | 72.3 kB | 196.7 kB | 1160 kB | 67.9 MB |
| plaintext v3 JSON | 41.3 kB | 108.2 kB | 926 kB | 38.8 MB |
| cloud envelope before (v1, no compression) | 96.5 kB | 262.4 kB | 1547 kB | 90.6 MB |
| cloud envelope after (v2, compressed) | 14.4 kB | 34.3 kB | 287 kB | 13.5 MB |
| SQLite cache before (gzip-4 of v2) | 16.3 kB | 42.3 kB | 276 kB | 15.3 MB |
| SQLite cache after (deflate frame of v3) | 11.6 kB | 28.2 kB | 215 kB | 10.9 MB |

0 mismatches: for every chat, v2 -> messages equals v2 -> v3 -> frame ->
encrypt -> decrypt -> messages. Run it with
`CHUK_REAL_DATA=1 flutter test test/manual/chat_payload_v3_real_data_test.dart`
(needs the read-only copy in `_scratch/dbcopy/chat_cache.db`).

## Old clients

There is no remote switch. This app writes v3 at once and migrates at once;
users of older builds must update. What an older build does with v3:

- Cloud: its decrypt checks `v == "1"` and throws
  `StateError('Unsupported ciphertext version: 2')` before touching the bytes.
  The batch decrypt returns null, and the sync shows the chat as a locked
  placeholder. A locked chat cannot be opened, renamed or continued, so the
  old build never writes over it. Titles stay v1 envelopes, so its sidebar
  still shows the names.
- Cache (a downgrade on the same device): its gzip decoder throws on a
  frame, the chat load returns null, the chat does not open. Every row is a
  frame, so an old build never sees v3 JSON as plain TEXT, which it would
  misread as v1.
- Proven by `test/services/chat_payload_envelope_test.dart` ("an old client
  meets v3"), which runs the old reader code verbatim.

Known limits: an old build with a stale v2 cache copy can still open that
copy and save it, which overwrites the newer cloud row with its older view
(the same last-writer-wins as between any two devices; the result is a valid
v2 payload, not garbage). A password change made on an old build skips the
v3 chats it cannot read; they stay sealed with the previous key and the new
build recovers them through the normal "locked chats" recovery.

## Migration: the maintenance screen

The rewrite of old chats runs once, **behind a blocking screen, before any
chat UI loads** (`lib/widgets/chat_maintenance_gate.dart`, wrapped around
the shell in `main.dart`; `AppInitializationService.initializeUserSession`
and the Agents bootstrap wait for it before they load chats). Text in every
app language: "Please do not close the app. Your data is being rewritten.",
with two bars: migration n of N, verification n of N. Not throttled; up to 4
chats at a time. Code: `lib/services/chat_payload_migration_service.dart`.

Plan (`ChatPayloadMigrationService.plan`): nothing when `kv_cache` holds the
done flag (`chat_payload_v3_migration_<user id>`). Otherwise the cache rows
that are not a frame yet (one SQL query, no payloads read) and the cloud
chats whose envelope still starts with `{"v":"1"` (one PostgREST query, ids
only), minus dirty chats and the ones skipped for good. No work: no screen.

Run (`execute`):

1. Backup: `VACUUM INTO chat_cache.backup.db` next to the cache.
2. Local: each row is converted and proven in an isolate (v3 must give the
   same messages), and written only while the row is unchanged.
3. Local verification: every rewritten row is read back, decoded and its
   fingerprint compared with the original's. Any fault: the backup is put
   back, the screen shows an error with **Retry** and **Continue**. Continue
   is safe: the reader reads v1 and v2, and the cache is as before.
4. Cloud: read the row, convert and prove it in an isolate, then
   `UPDATE … SET encrypted_payload, updated_at = <read> + 1 µs WHERE
   updated_at = <read>`. The trigger `encrypted_chats_touch_updated_at()`
   (`supabase/migrations/20260924120000_encrypted_chats_keep_client_updated_at.sql`)
   keeps an `updated_at` the client changed on purpose, so the sidebar order
   and dates stay; a normal save still gets `NOW()`. A save that came in
   meanwhile fails the guard and wins. The cache row gets the same new
   `updated_at`, so the next sync does not download the chat again.
5. Cloud verification: the envelope that was written is decrypted, decoded
   and fingerprinted against the original. A mismatch writes the original
   ciphertext back and ends with an error (no re-download needed: the bytes
   that were written are known).
6. Done flag set, backup deleted.

Offline or a cloud error: the local part is finished, the cloud chats that
are left keep their `{"v":"1"}` envelope and are found again at the next
start, where the screen shows only for them. Nothing is half written: each
cloud chat is one UPDATE, the cache is restored as a whole. Skipped: dirty
chats (their next cloud save is v3), locked chats (another key; the recovery
flow writes v3), chats that fail the proof (left readable as they are), and
Agents threads.

Web: no cache database, so only the cloud part runs, behind the same screen.
There are no isolates on the web, so the conversion runs on the UI thread and
seals with deflate only; the screen stays up while it runs.
