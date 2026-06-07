# Task: Single image-gen tool (model param) + cancel-bug fix

## Goal
1. ONE `generate_image` tool. AI picks generator via `model` param. Adding a
   generator = one registry entry (both server + client).
2. Fold all imaging into it: turbo | hunyuan | flux | ideogram | edit.
   Ideogram v4 now live on API — expose it.
3. Fix cancel bug: cancelling a response still resumes a few seconds later
   (next agentic pass fires after in-flight tool finishes).

Decisions: FULL server rewrite (config-driven, shared billing). Fold `edit`
into generate_image. `fetch_image` stays separate (client-only download, no
model/cost).

---

## Part A — Server (`/home/user/git/api_server`)

`main.py`:
- [ ] Add `ImageGenerator` spec + `IMAGE_GENERATORS` registry (turbo, hunyuan,
      flux, ideogram, edit). Each entry: billing_model_id, analytics_backend,
      endpoint_label, `prepare(params)` -> (model_ref, replicate_input,
      cost_usd, extra_response, output_mode, log_detail).
- [ ] Add shared core `_run_image_generation(gen, user, request, params)`:
      token-check -> rate limit -> prepare/validate -> billing pre-deduct ->
      replicate.run -> extract url (single/list/ideogram modes) -> analytics ->
      unified return. On failure: refund + analytics + raise. (Collapses the 5
      duplicated endpoint bodies.)
- [ ] New endpoint `POST /v1/ai/image/generate` (model=Form, all optional
      params) -> dispatch via registry.
- [ ] Rewrite the 5 existing endpoints (turbo/hunyuan/flux/edit/ideogram) as
      thin wrappers calling `_run_image_generation` (backward compat for old
      clients + old chats).

`routers/multiplex.py`:
- [ ] Replace `_tool_image_turbo/hunyuan/flux/edit` with one
      `_tool_image_generate` reading `payload["model"]`.
- [ ] Registry: add `"image_generate"`. Keep old `image_*` names as aliases
      (inject model) for in-flight old clients.

## Part B — Flutter client (`/home/user/git/chuk_chat`)

- [ ] `tool_registry.dart`: replace the 3 generator defs + `edit_image` with ONE
      `generate_image` (model enum + per-model optional params + caption).
      Update `toolCategoryMap` (drop hunyuan/flux/edit; keep generate_image,
      fetch_image, view_chat_images).
- [ ] `tool_handlers/image_tools.dart`: single `executeGenerateImage(args)` with
      a `_imageModels` map (display name + allowed params per model). Routes to
      `/v1/ai/image/generate` + mux `image_generate`. Fold edit in (model=edit,
      image_url). Drop the 3 separate executors + executeEditImage. Keep
      executeFetchImage.
- [ ] `tool_executor.dart`: single `generate_image` case; drop hunyuan/flux/edit
      cases + names from executable list. Keep fetch_image.
- [ ] `find_tools_handler.dart`: companions -> generate_image bundles
      fetch_image/view_chat_images only.
- [ ] `tool_prompt_builder.dart`: rewrite image guidance for one tool + model
      selection.
- [ ] `tool_parser.dart`: keep only `generate_image` among image gen names.
- [ ] Sweep `tool_enforcer.dart`, `customization_page.dart`,
      `tool_calling_settings_page.dart` for removed names; update.

## Part C — Cancel bug (`streaming_message_handler.dart`)
- [ ] Add `bool _cancelRequested`. Reset false at send entrypoint.
- [ ] `cancelStream()` sets it true.
- [ ] Guard top of `startStreamingPass` + before both recursive
      `startStreamingPass(currentPass+1)` calls (lines ~725, ~808): if
      `_cancelRequested` -> release keepalive + return (no next pass).

## Verify
- [ ] `flutter analyze` clean
- [ ] `flutter test` all pass
- [ ] api_server import/pytest sanity
- [ ] coderabbit review, then commit + push (both repos)

## Review

Done:
- Server (`api_server`): added `ImageGenerator` registry + `PreparedImageJob` +
  shared `_run_image_generation` core (5 endpoint bodies → 5 tiny `prepare_*`
  fns). New `POST /v1/ai/image/generate` (model param). 5 old endpoints now thin
  wrappers (backward compat). Mux: `_tool_image_generate` + legacy `image_*`
  aliases; registry has `image_generate`. `main` imports clean; registry =
  turbo/hunyuan/flux/ideogram/edit. Ideogram now reachable via mux.
- Client (`chuk_chat`): one `generate_image` ClientTool with `model` enum +
  per-model params; `image_tools.executeGenerateImage` routes by model to
  `/v1/ai/image/generate` (mux `image_generate`); edit folded in. Removed
  hunyuan/flux/edit executors, cases, names across tool_executor, tool_registry,
  tool_enforcer, tool_call_handler, tool_parser, find_tools companions,
  tool_prompt_builder. fetch_image untouched.
- Cancel bug: `_cancelRequested` flag — reset on send, set in `cancelStream`,
  checked at top of `startStreamingPass` + before both recursive next-pass calls
  → no ghost-resume after an in-flight tool finishes.

Verify: `flutter analyze` clean · `flutter test` 745 pass · api_server imports +
prompt test pass.

Pending: CodeRabbit, commit + push (both repos).
