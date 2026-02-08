# Bug Fix Plan: Chat Duplication & Wrong Chat Streaming

## Problem Statement
When sending a message with an image in a new chat:
1. The response streams into an OLD chat instead of the new one
2. Chats get duplicated in the sidebar
3. Images from different chats get mixed up

## Root Cause Analysis

### Current Architecture Issues

1. **Index-Based Chat Selection**
   - `ChatStorageService.selectedChatIndex` is a global static variable
   - Parent widgets read this value on every rebuild
   - When chats are added, indices shift (new chat = index 0, old chats shift down)
   - This creates race conditions between UI updates and chat creation

2. **Multiple Sources of Truth**
   - `ChatStorageService.selectedChatIndex` - global index
   - `_activeChatId` in chat UI - local chat ID
   - `widget.selectedChatIndex` - passed from parent
   - These can get out of sync

3. **Asynchronous Operations**
   - Chat persistence is async
   - Streaming is async with callbacks
   - Parent can rebuild at any time during these operations
   - `didUpdateWidget` fires whenever parent rebuilds

4. **Realtime Events**
   - Supabase realtime events can trigger `_notifyChanges()`
   - This causes UI rebuilds and potential index mismatches

## Investigation Steps

### Step 1: Trace the Full Flow
- [ ] Add comprehensive logging to trace:
  - When `selectedChatIndex` changes and WHY
  - When parent widgets rebuild and WHY
  - When `didUpdateWidget` is called
  - When `_activeChatId` changes

### Step 2: Identify Trigger Points
- [ ] Find all places that modify `ChatStorageService.selectedChatIndex`
- [ ] Find all places that call `setState()` in parent widgets
- [ ] Find all places that trigger parent rebuilds

### Step 3: Understand the Race Condition
- [ ] Document exact sequence of events when bug occurs
- [ ] Identify the specific moment when wrong chat is loaded

## Proposed Solutions

### Solution A: Lock-Based Approach (Quick Fix)
Add a global lock that prevents chat switching during message operations.

```dart
// In ChatStorageService
static bool isMessageOperationInProgress = false;

// In chat UI
void _sendMessage() {
  ChatStorageService.isMessageOperationInProgress = true;
  // ... send message ...
  // Clear in onComplete callback
}

// In didUpdateWidget
if (ChatStorageService.isMessageOperationInProgress) {
  return; // Don't switch chats
}
```

### Solution B: Chat ID-Based Selection (Better Fix)
Change from index-based to ID-based chat selection.

```dart
// Instead of selectedChatIndex, use selectedChatId
static String? selectedChatId;

// Parent passes chat ID, not index
ChukChatUIDesktop(
  selectedChatId: ChatStorageService.selectedChatId,
  // ...
)

// didUpdateWidget compares IDs, not indices
if (widget.selectedChatId != oldWidget.selectedChatId) {
  // Load chat by ID
}
```

### Solution C: Callback-Based Chat Creation (Cleanest Fix)
New chat creation should be managed by parent, not child.

```dart
// Parent creates chat ID and manages state
void _handleNewChatRequested() {
  final newChatId = Uuid().v4();
  setState(() {
    _currentChatId = newChatId;
  });
}

// Child just receives the chat ID
ChukChatUIDesktop(
  chatId: _currentChatId, // Can be null for new chat
  onChatCreated: (chatId) => setState(() => _currentChatId = chatId),
)
```

## Implementation Plan

### Phase 1: Diagnostic (Do First)
1. Add comprehensive logging to understand exact failure sequence
2. Test and capture logs showing the race condition
3. Identify exact trigger point

### Phase 2: Quick Fix (Solution A)
1. Add global lock flag to ChatStorageService
2. Set flag at start of message send
3. Clear flag when streaming completes
4. Check flag in didUpdateWidget of BOTH mobile and desktop

### Phase 3: Proper Fix (Solution B)
1. Add `selectedChatId` to ChatStorageService
2. Update parent wrappers to pass chat ID
3. Update chat UIs to use chat ID instead of index
4. Remove index-based logic

### Phase 4: Cleanup
1. Remove old index-based code
2. Remove diagnostic logging
3. Test thoroughly

## Files to Modify

1. `lib/services/chat_storage_service.dart`
   - Add `selectedChatId` field
   - Add `isMessageOperationInProgress` lock

2. `lib/platform_specific/root_wrapper_mobile.dart`
   - Pass chat ID instead of index
   - Handle chat creation callback

3. `lib/platform_specific/root_wrapper_desktop.dart`
   - Pass chat ID instead of index
   - Handle chat creation callback

4. `lib/platform_specific/chat/chat_ui_mobile.dart`
   - Use chat ID for selection
   - Set/clear global lock during send

5. `lib/platform_specific/chat/chat_ui_desktop.dart`
   - Use chat ID for selection
   - Set/clear global lock during send

6. `lib/platform_specific/sidebar_mobile.dart`
   - Update to use chat ID

7. `lib/platform_specific/sidebar_desktop.dart`
   - Update to use chat ID

## Success Criteria

1. New chat with image stays in new chat UI
2. Streaming response goes to correct chat
3. No duplicate chats in sidebar
4. Images stay with correct messages
5. Works on both mobile and desktop
6. Works with rapid chat switching
7. Works with realtime sync enabled
