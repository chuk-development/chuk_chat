# Chat-UI Perf Follow-up (branch: agent/chat-ui-perf-followup)

PR scope decided: all 3 refactors in ONE PR → CodeRabbit → fix → **STOP before merge**.
User does manual QA on Android + Desktop, then merge.

Verification constraint: no Android device; Linux window won't screenshot-render;
799 tests are pure-logic (no mocking) → they do NOT catch persistence/streaming
regressions. Correctness leans on tests + CodeRabbit + user's manual QA gate.

## 1. Mobile model/reasoning merged pill — DONE
- Extracted `ReasoningSegmentButton` -> `lib/widgets/reasoning_segment_button.dart`
- Desktop uses shared widget; mobile `_buildModelControl` renders merged pill
- 799 tests green, analyze clean. Commit done.

## 2. Typed message model — IN PROGRESS
Replace `List<Map<String,String>> _messages` (mobile+desktop) + `ChatRuntime.messages`
with typed immutable model; stable per-message-id keys instead of `ValueKey('msg_$i')`.
- [ ] Decide model: reuse/extend `ChatMessage` (add ephemeral tps/lastError/debugRequests) vs UI wrapper
- [ ] Assign stable id to EVERY message at creation (user+assistant+placeholder)
- [ ] Fix mobile `_applyLoadedChat` losing messageId; desktop `messageToRawMap` losing status/queueId/tps
- [ ] Migrate widget `_messages` both platforms
- [ ] Migrate `ChatRuntime.messages` + by-ref lists (streaming_message_handler, desktop_send_logic, chat_persistence_handler)
- [ ] Unify read path (mobile inlines vs desktop buildMessageRenderData)
- [ ] Switch list keys to stable id
- [ ] Tests green

## 3. Streaming de-dup + Riverpod — TODO (highest risk)
- [ ] Migrate `ChatRuntimeRegistry` singleton -> Riverpod `NotifierProvider.family` (pure plumbing, no behavior change)
- [ ] Collapse desktop's OWN duplicated pass loop (edit vs send) first
- [ ] Route desktop through shared `StreamingMessageHandler` (adds retries/persistence/segmented blocks/cancellation-model change to desktop — BEHAVIOR CHANGE, needs desktop QA)
- [ ] Reconcile desktop offline-enqueue + operation-id cancellation with handler's `_cancelRequested`
- [ ] Tests green

## 4. Finish
- [ ] flutter analyze clean, flutter test green
- [ ] coderabbit review --plain --type uncommitted -> fix findings
- [ ] Push branch, open PR, wait CodeRabbit, fix
- [ ] STOP. Hand to user for Android+Desktop QA. Do NOT merge.
