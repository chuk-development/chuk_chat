# Privacy claims for marketing (checked against the code, 2026-10-26)

Every video, post and ad uses only the "may say" column. Evidence paths are
in the check report summarised here; re-check when the code changes.
Prefix `C:` = this repo, `S:` = `~/git/api_server`.

**Ground rule.** "Encrypted" means stored at rest in Supabase. Inference is
not end-to-end: api.chuk.chat and the model provider get the messages,
images and tool results in plain text to answer. Never say "end-to-end
encrypted conversation", "even we can't read it", "not even the AI".

| Topic | May say | Must not say | Evidence |
|---|---|---|---|
| Chats | Encrypted on your device (AES-256-GCM) before we store them. Our server stores only ciphertext. The key comes from your password, on your device. | Nobody can read your chats. End-to-end encrypted chat. | C:lib/services/encryption_service.dart:52-67, 357, 379 |
| Files and images | Your photos, scans and files are encrypted on your device before they are stored. Storage only holds `.enc` ciphertext. | The server never sees your files (PDF/Office conversion and the model get plain text). | C:lib/services/image_storage_service.dart:101-185 |
| Generated images | Made with zero data retention (`zdr`, `data_collection: deny`), kept in server RAM at most 15 min, then stored encrypted. | The server never sees your prompts or images. | S:routers/ai/images.py:51-87 |
| Workspaces and memory | Your instructions, file names, file text and memory are encrypted on your device before they are stored. | Everything about a workspace is encrypted (sizes, types, timestamps are plain). | C:lib/services/workspace_storage_service.dart:81-94, 345-385 |
| Models | Open-weight models (GLM, DeepSeek, Qwen, Kimi, ...). OpenRouter routes are filtered to zero-data-retention endpoints. | "Every model has zero data retention" (Melious and OrcaRouter routes carry no ZDR flag; GLM 5.3 Flash goes via OrcaRouter). Contractual no-training. Providers never see your prompts. | S:chat/upstream.py:48-107, S:model_info/service.py:954-1062 |
| Search | Searching your chats happens on your device. There is no server search. | Your local cache is encrypted. | C:lib/services/local_chat_cache_native.dart:701-729 |
| Connectors | Sign-in runs directly between your device and the service; tokens stay in your device's secure storage, the backup is encrypted on the device. Show Notion, Linear, Todoist. | Any token claim for GitHub (server-held, Fernet). "The server never holds a connector token." | C:lib/services/mcp/mcp_store.dart:1-26 |
| Account | An email and a password. No phone number, no Google or Apple login. Delete your account any time. | Anonymous, no email needed. | C:lib/services/auth_service.dart:33-45 |
| Tracking | No ads, no tracking SDK in the app. Server analytics count tokens and latency, never your words (content fields stripped). | We log nothing about you. | S:services/analytics.py:48-70, 150-200 |
| Code | The app's source code is public on GitHub. Read it. | Open source (licence is BSL 1.1, see bead chuk_chat-yekx). The server code is public. | C:LICENSE |
| Germany | Run from Germany, under EU law. (site claim) | — | chuk.chat |
| Training | Never used for training. (site claim, provider ZDR) | Contractual guarantee. | chuk.chat, S:docs/ZDR_PROVIDER_ANALYSIS.md |
| Voice / Android assistant | — (speech goes to Groq Whisper, no ZDR found) | On-device AI, offline assistant, private voice. | S:routers/ai/transcribe.py |
