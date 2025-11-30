# Projects Feature Implementation Plan

## Overview

The Projects feature allows users to create workspaces that group related chats, files, and custom AI system prompts. This enables organized, context-aware conversations with the AI across both desktop and mobile platforms.

## Core Features

1. **Project Workspaces**: Create named projects with descriptions
2. **Custom System Prompts**: Define AI behavior per project
3. **Chat Assignment**: Add existing chats to one or more projects
4. **File Attachments**: Upload files that the AI can access as context
5. **Cross-Platform**: Full support for desktop and mobile UIs

---

## Database Schema (Supabase)

### Table: `projects`

Stores project metadata and configuration.

```sql
CREATE TABLE projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  custom_system_prompt TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_archived BOOLEAN NOT NULL DEFAULT FALSE
);

-- RLS Policies
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own projects"
  ON projects FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own projects"
  ON projects FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own projects"
  ON projects FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own projects"
  ON projects FOR DELETE
  USING (auth.uid() = user_id);

-- Index for performance
CREATE INDEX idx_projects_user_id ON projects(user_id);
CREATE INDEX idx_projects_created_at ON projects(created_at DESC);
```

### Table: `project_chats`

Many-to-many relationship between projects and chats.

```sql
CREATE TABLE project_chats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL REFERENCES encrypted_chats(id) ON DELETE CASCADE,
  added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(project_id, chat_id)
);

-- RLS Policies
ALTER TABLE project_chats ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own project chats"
  ON project_chats FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_chats.project_id
      AND projects.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can add chats to their own projects"
  ON project_chats FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_chats.project_id
      AND projects.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can remove chats from their own projects"
  ON project_chats FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_chats.project_id
      AND projects.user_id = auth.uid()
    )
  );

-- Indexes for performance
CREATE INDEX idx_project_chats_project_id ON project_chats(project_id);
CREATE INDEX idx_project_chats_chat_id ON project_chats(chat_id);
```

### Table: `project_files`

Stores metadata for encrypted file attachments. Files themselves are stored in Supabase Storage (project-files bucket).

```sql
CREATE TABLE project_files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  file_name TEXT NOT NULL,
  storage_path TEXT NOT NULL,
  file_type TEXT NOT NULL,
  file_size BIGINT NOT NULL,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS Policies
ALTER TABLE project_files ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view files in their own projects"
  ON project_files FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_files.project_id
      AND projects.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can upload files to their own projects"
  ON project_files FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_files.project_id
      AND projects.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can delete files from their own projects"
  ON project_files FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_files.project_id
      AND projects.user_id = auth.uid()
    )
  );

-- Index for performance
CREATE INDEX idx_project_files_project_id ON project_files(project_id);
```

---

## Data Models

### `lib/models/project_model.dart`

```dart
class Project {
  final String id;
  final String name;
  final String? description;
  final String? customSystemPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isArchived;

  // Loaded separately via joins
  final List<String> chatIds;
  final List<ProjectFile> files;

  Project({
    required this.id,
    required this.name,
    this.description,
    this.customSystemPrompt,
    required this.createdAt,
    required this.updatedAt,
    this.isArchived = false,
    this.chatIds = const [],
    this.files = const [],
  });

  factory Project.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();

  Project copyWith({...});

  // Helper: Get chat count
  int get chatCount => chatIds.length;

  // Helper: Get file count
  int get fileCount => files.length;

  // Helper: Has custom system prompt
  bool get hasCustomPrompt =>
    customSystemPrompt != null && customSystemPrompt!.isNotEmpty;
}

class ProjectFile {
  final String id;
  final String projectId;
  final String fileName;
  final String encryptedContent;
  final String fileType;
  final int fileSize;
  final DateTime uploadedAt;

  ProjectFile({
    required this.id,
    required this.projectId,
    required this.fileName,
    required this.encryptedContent,
    required this.fileType,
    required this.fileSize,
    required this.uploadedAt,
  });

  factory ProjectFile.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();

  // Helper: Get file size as human readable string
  String get fileSizeFormatted;

  // Helper: Get file icon based on type
  IconData get fileIcon;
}
```

---

## Services Layer

### `lib/services/project_storage_service.dart`

Manages project CRUD operations, chat assignments, and file handling.

**Key Features**:
- Single source of truth: `Map<String, Project> _projectsById`
- Stream-based change notifications: `Stream<void> changes`
- Encryption integration for file content
- Offline support via caching
- Selected project tracking: `selectedProjectId`

**Methods**:

#### Project CRUD
- `Future<void> loadProjects()` - Load all projects from Supabase
- `Future<Project> createProject(String name, {String? description, String? systemPrompt})`
- `Future<Project> updateProject(String projectId, {String? name, String? description, String? systemPrompt})`
- `Future<void> deleteProject(String projectId)` - Delete project and all associations
- `Future<void> archiveProject(String projectId, bool archived)`
- `Project? getProject(String projectId)` - Get project from cache
- `List<Project> get projects` - Get all projects sorted by created date

#### Chat Management
- `Future<void> addChatToProject(String projectId, String chatId)`
- `Future<void> removeChatFromProject(String projectId, String chatId)`
- `Future<List<StoredChat>> getProjectChats(String projectId)` - Get all chats in project
- `Future<List<Project>> getChatProjects(String chatId)` - Get all projects containing chat

#### File Management
- `Future<ProjectFile> uploadFile(String projectId, String fileName, Uint8List fileBytes, String fileType)`
- `Future<void> deleteFile(String projectId, String fileId)`
- `Future<List<ProjectFile>> getProjectFiles(String projectId)`
- `Future<String> decryptFile(String fileId)` - Decrypt file content for AI context

#### State Management
- `static String? selectedProjectId` - Currently active project
- `static Stream<void> get changes` - Listen to project updates
- `static void reset()` - Clear all project data on logout

### `lib/services/project_message_service.dart`

Composes AI messages with project context (system prompt + files).

**Methods**:

- `Future<String> buildProjectSystemMessage(String projectId)`
  - Returns formatted system message including:
    - Project name and description
    - Custom system prompt
    - List of available files with metadata

- `Future<List<Map<String, dynamic>>> injectProjectContext(String projectId, List<Map<String, dynamic>> messages)`
  - Prepends project context as system message to conversation
  - Includes decrypted file contents (up to size limit)
  - Format: "You are working in project '{name}'. {description}\n\nSystem Prompt: {prompt}\n\nAvailable Files:\n{file_contents}"

- `static const int maxFileContentLength = 50000` - Limit file context size

---

## UI Implementation

### Desktop UI

#### `lib/pages/projects_page.dart` - Projects List (Desktop)

**Layout**:
```
┌─────────────────────────────────────────────┐
│  ← Projects                    [+ New]      │
├─────────────────────────────────────────────┤
│  Search: [________________]                 │
├─────────────────────────────────────────────┤
│  ┌──────────────────────────────────────┐  │
│  │  📁 AI Research Assistant      [⋮]   │  │
│  │  Research and document AI topics     │  │
│  │  💬 5 chats  📄 3 files  ⚙️ Custom   │  │
│  └──────────────────────────────────────┘  │
│  ┌──────────────────────────────────────┐  │
│  │  📁 Code Review Helper         [⋮]   │  │
│  │  Help review and improve code        │  │
│  │  💬 12 chats  📄 0 files             │  │
│  └──────────────────────────────────────┘  │
│  ┌──────────────────────────────────────┐  │
│  │  📁 Writing Assistant          [⋮]   │  │
│  │  Creative writing and editing        │  │
│  │  💬 3 chats  📄 1 file  ⚙️ Custom    │  │
│  └──────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

**Features**:
- Search/filter projects by name
- Card-based layout with project metadata
- Badges: chat count, file count, custom prompt indicator
- Context menu (⋮): Edit, Archive, Delete
- Tap card to open project detail
- "+" button opens create project dialog

#### `lib/pages/project_detail_page.dart` - Project Detail (Desktop)

**Layout**:
```
┌─────────────────────────────────────────────────┐
│  ← AI Research Assistant              [Edit]   │
├─────────────────────────────────────────────────┤
│  Research and document AI topics                │
│  Created: Jan 15, 2025 • Updated: Jan 20, 2025  │
├─────────────────────────────────────────────────┤
│  [Chats] [Files] [Settings]                     │
├─────────────────────────────────────────────────┤
│  CHATS TAB:                                     │
│  ┌──────────────────────────────────────────┐  │
│  │  [+ Add Chat to Project]                 │  │
│  └──────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────┐  │
│  │  💬 How does GPT-4 work?          [×]    │  │
│  │     Exploring transformer architecture   │  │
│  │     Jan 15 • 23 messages                 │  │
│  └──────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────┐  │
│  │  💬 RAG implementation guide      [×]    │  │
│  │     Building retrieval systems           │  │
│  │     Jan 18 • 45 messages                 │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

**Tabs**:

1. **Chats Tab**:
   - List of chats in project
   - "Add Chat" button → Opens chat selector dialog
   - Each chat shows: preview text, date, message count
   - Remove button (×) to unlink chat from project
   - Tap chat → Opens in desktop chat UI with project context active

2. **Files Tab**:
   - List of uploaded files
   - "Upload File" button → File picker dialog
   - Each file shows: name, type icon, size, upload date
   - Actions: Preview (text files), Download, Delete
   - Max file size: 10MB (from FileConstants)

3. **Settings Tab**:
   - Project name (editable)
   - Description (editable text area)
   - Custom System Prompt (large text area with markdown support)
   - Archive/Delete project buttons (with confirmation)

### Mobile UI

#### `lib/pages/projects_page_mobile.dart` - Projects List (Mobile)

**Layout**:
```
┌─────────────────────────┐
│  ☰  Projects      [+]   │
├─────────────────────────┤
│  [Search projects...]   │
├─────────────────────────┤
│  ┌───────────────────┐  │
│  │ 📁 AI Research    │  │
│  │ Research AI...    │  │
│  │ 💬 5  📄 3  ⚙️    │  │
│  └───────────────────┘  │
│  ┌───────────────────┐  │
│  │ 📁 Code Review    │  │
│  │ Help review code  │  │
│  │ 💬 12  📄 0       │  │
│  └───────────────────┘  │
│  ┌───────────────────┐  │
│  │ 📁 Writing Assist │  │
│  │ Creative writing  │  │
│  │ 💬 3  📄 1  ⚙️    │  │
│  └───────────────────┘  │
└─────────────────────────┘
```

**Features**:
- Compact card layout optimized for mobile
- Pull-to-refresh to reload projects
- Long-press on card for context menu (Edit, Archive, Delete)
- Tap card to open project detail
- FAB (+) button for creating new project

#### `lib/pages/project_detail_page_mobile.dart` - Project Detail (Mobile)

**Layout**:
```
┌─────────────────────────┐
│  ← AI Research     [⋮]  │
├─────────────────────────┤
│  Research and document  │
│  AI topics              │
├─────────────────────────┤
│ [Chats][Files][Config]  │
├─────────────────────────┤
│  CHATS TAB:             │
│  ┌───────────────────┐  │
│  │ [+ Add Chat]      │  │
│  └───────────────────┘  │
│  ┌───────────────────┐  │
│  │ 💬 How does GPT-4 │  │
│  │ work?        [×]  │  │
│  │ Jan 15 • 23 msgs  │  │
│  └───────────────────┘  │
│  ┌───────────────────┐  │
│  │ 💬 RAG guide [×]  │  │
│  │ Jan 18 • 45 msgs  │  │
│  └───────────────────┘  │
└─────────────────────────┘
```

**Tabs** (same as desktop but mobile-optimized):
- Bottom navigation or swipeable tabs
- Compact list items
- Bottom sheet dialogs for Add Chat / Upload File
- Tap chat → Opens in mobile chat UI with project context

#### Mobile Chat UI Integration

**`lib/platform_specific/chat/chat_ui_mobile.dart` Updates**:

**Project Context Banner** (when projectId is set):
```
┌─────────────────────────┐
│ 📁 AI Research          │
│ ⚙️ Custom prompt active │
│ 📄 3 files available    │
│ [View] [Exit]           │
└─────────────────────────┘
```

**Features**:
- Collapsible banner at top of chat
- "View" → Opens project detail page
- "Exit" → Clears project context from current chat
- Project context automatically injected into messages

---

## Chat UI Integration (Both Platforms)

### Desktop: `lib/platform_specific/chat/chat_ui_desktop.dart`

**Changes**:
- Add `String? projectId` parameter to `ChukChatUIDesktop`
- Add `Project? _currentProject` state variable
- Load project on init if `projectId` is set
- Display project context banner in header area
- Pass `projectId` to `StreamingMessageHandler` for context injection

**Project Banner Component**:
```dart
Widget _buildProjectBanner(Project project) {
  return Container(
    padding: EdgeInsets.all(12),
    color: Theme.of(context).accentColor.withOpacity(0.1),
    child: Row(
      children: [
        Icon(Icons.folder_open, size: 20),
        SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(project.name, style: TextStyle(fontWeight: FontWeight.bold)),
              if (project.hasCustomPrompt)
                Text('Custom system prompt active', style: TextStyle(fontSize: 12)),
              if (project.fileCount > 0)
                Text('${project.fileCount} files available', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        TextButton(child: Text('View Details'), onPressed: () { /* Open project detail */ }),
        IconButton(icon: Icon(Icons.close), onPressed: _exitProjectMode),
      ],
    ),
  );
}
```

### Mobile: `lib/platform_specific/chat/chat_ui_mobile.dart`

**Changes**:
- Add `String? projectId` parameter to `ChukChatUIMobile`
- Add collapsible project banner at top of message list
- Same context injection as desktop
- Optimize banner for mobile (smaller, collapsible)

---

## Message Composition Integration

### `lib/platform_specific/chat/handlers/streaming_message_handler.dart`

**Changes**:
- Add `String? projectId` parameter to send methods
- Before sending message, check if `projectId` is set
- If yes: Call `ProjectMessageService.injectProjectContext()`
- This prepends system message with project context to conversation

**Example Flow**:
```dart
Future<void> sendMessage(
  List<Map<String, dynamic>> messages, {
  String? projectId,
}) async {
  List<Map<String, dynamic>> finalMessages = messages;

  // Inject project context if active
  if (projectId != null) {
    finalMessages = await ProjectMessageService.injectProjectContext(
      projectId,
      messages,
    );
  }

  // Continue with normal streaming logic...
}
```

---

## Chat Assignment UI

### Option 1: From Sidebar (Context Menu)

**Desktop (`lib/platform_specific/sidebar_desktop.dart`)**:
- Add "Add to Project" option in chat context menu (right-click or ⋮)
- Opens dialog with project selector (checkboxes)
- Can select multiple projects
- Shows which projects chat is already in

**Mobile (`lib/platform_specific/sidebar_mobile.dart`)**:
- Long-press on chat in drawer
- Shows bottom sheet with "Add to Project" option
- Same multi-select project picker

### Option 2: From Project Detail Page

**Both Platforms**:
- "Add Chat" button in Chats tab
- Opens searchable chat selector dialog
- Lists all user chats with preview text
- Filter by search query
- Select chat → Immediately adds to project
- Shows "Already added" for chats in project

---

## File Handling

### Supported File Types
- **Text files**: .txt, .md, .json, .yaml, .csv
- **Code files**: .dart, .js, .py, .java, .cpp, .rs, .go, .html, .css
- **Documents**: .pdf (convert to text using file_conversion_service.dart)
- **Max size**: 10MB per file (from `FileConstants.maxFileSizeBytes`)

### Upload Flow
1. User selects file via file picker
2. Read file content as bytes
3. Convert to text if necessary (PDF → text)
4. Encrypt content using `EncryptionService.encrypt()`
5. Upload to Supabase `project_files` table
6. Add to local project cache

### Download/Preview Flow
1. Fetch encrypted content from Supabase
2. Decrypt using `EncryptionService.decrypt()`
3. For preview: Display in modal with syntax highlighting
4. For download: Save to device storage

### AI Context Injection
- When loading project for chat, decrypt all files
- Concatenate file contents with metadata
- Include in system message: `"File: {name} ({type}, {size})\n\n{content}\n\n---\n\n"`
- Limit total file content to 50KB to avoid token limits

---

## Implementation Order

### Phase 1: Database & Models (Day 1)
1. Create SQL migration file (`migrations/projects.sql`)
2. Run migration in Supabase dashboard
3. Test tables and RLS policies
4. Implement `lib/models/project_model.dart`
5. Write unit tests for models

### Phase 2: Services Layer (Day 2-3)
6. Implement `ProjectStorageService` (CRUD operations)
7. Implement file upload/download with encryption
8. Implement chat assignment logic
9. Implement `ProjectMessageService` (context injection)
10. Test all service methods

### Phase 3: Desktop UI (Day 4-5)
11. Build `ProjectsPage` (list view)
12. Build `ProjectDetailPage` (tabs: Chats, Files, Settings)
13. Add project context banner to `ChukChatUIDesktop`
14. Integrate chat assignment from sidebar
15. Test full desktop workflow

### Phase 4: Mobile UI (Day 6-7)
16. Build mobile `ProjectsPage` (optimized layout)
17. Build mobile `ProjectDetailPage` (swipeable tabs)
18. Add project context banner to `ChukChatUIMobile`
19. Integrate chat assignment from mobile drawer
20. Test full mobile workflow

### Phase 5: Integration & Testing (Day 8)
21. Test project context injection in messages
22. Test file content in AI responses
23. Test multi-project chat assignment
24. Test offline support and caching
25. Test encryption/decryption of files
26. Fix bugs and polish UI

### Phase 6: Documentation & Deployment (Day 9)
27. Update CLAUDE.md with Projects documentation
28. Add Projects section to README (if applicable)
29. Test migration on clean database
30. Commit and push all changes

---

## Advanced Features (Future Enhancements)

### Templates
- Pre-configured project templates (e.g., "Code Review", "Research", "Writing")
- Template marketplace for sharing configurations

### Sharing
- Share projects with other users (read-only or edit)
- Team workspaces with shared projects

### Analytics
- Track token usage per project
- View project activity timeline
- Export project statistics

### File Versioning
- Track file changes over time
- Restore previous file versions
- Diff viewer for file changes

### Export/Import
- Export project as ZIP (chats + files + config)
- Import project from ZIP
- Export to markdown/PDF for documentation

### AI Features
- Automatic project summarization
- Suggest chats to add based on content
- Smart file recommendations based on conversation

---

## Testing Checklist

### Functionality Tests
- [ ] Create project with name, description, system prompt
- [ ] Update project metadata
- [ ] Delete project (verify cascading delete of associations)
- [ ] Archive/unarchive project
- [ ] Add chat to project
- [ ] Remove chat from project
- [ ] Add chat to multiple projects
- [ ] Upload text file to project
- [ ] Upload PDF file to project (verify text extraction)
- [ ] Delete file from project
- [ ] Preview file content
- [ ] Download file
- [ ] View project in chat UI (desktop)
- [ ] View project in chat UI (mobile)
- [ ] Verify AI receives project context
- [ ] Verify AI receives file contents
- [ ] Search/filter projects
- [ ] Offline project access (cached data)

### Security Tests
- [ ] Verify RLS policies prevent unauthorized access
- [ ] Verify file encryption/decryption
- [ ] Verify files from other users cannot be accessed
- [ ] Verify project deletion removes all data

### UI/UX Tests
- [ ] Projects list renders correctly (desktop)
- [ ] Projects list renders correctly (mobile)
- [ ] Project detail tabs work (desktop)
- [ ] Project detail tabs work (mobile)
- [ ] Project banner shows in chat UI
- [ ] Chat assignment dialog works
- [ ] File upload dialog works
- [ ] Confirm dialogs for delete actions
- [ ] Loading states during async operations
- [ ] Error messages for failures

---

## File Structure Summary

```
lib/
├── models/
│   └── project_model.dart              # Project & ProjectFile classes
├── services/
│   ├── project_storage_service.dart    # CRUD, chat/file management
│   └── project_message_service.dart    # Context injection
├── pages/
│   ├── projects_page.dart              # Projects list (desktop)
│   └── project_detail_page.dart        # Project detail (desktop + mobile adaptive)
├── platform_specific/
│   ├── chat/
│   │   ├── chat_ui_desktop.dart        # [UPDATED] Add project context
│   │   └── chat_ui_mobile.dart         # [UPDATED] Add project context
│   ├── sidebar_desktop.dart            # [UPDATED] Add "Add to Project" menu
│   └── sidebar_mobile.dart             # [UPDATED] Add "Add to Project" menu
└── widgets/
    ├── project_card.dart               # Reusable project card widget
    ├── project_context_banner.dart     # Project info banner for chat UI
    ├── chat_selector_dialog.dart       # Multi-select chat picker
    └── file_preview_dialog.dart        # File content preview modal

migrations/
└── projects.sql                        # SQL migration for all tables
```

---

## SQL Migration File Location

**File**: `migrations/projects.sql`

This file will contain all CREATE TABLE and RLS policy statements.

**How to run**:
1. Open Supabase Dashboard → SQL Editor
2. Copy entire contents of `migrations/projects.sql`
3. Execute query
4. Verify tables created in Database → Tables

---

## Notes

- Projects feature is fully cross-platform (desktop + mobile)
- Files are encrypted client-side before upload (same as chats)
- A chat can belong to multiple projects simultaneously
- Deleting a project does NOT delete the associated chats (only unlinks them)
- Project context is injected at message send time, not stored permanently
- File content size is limited to prevent token overflow in AI context
- All project data respects Supabase RLS policies for security

---

## Questions for Clarification

1. **File size limit per project**: Should there be a total storage limit per user?
2. **Project templates**: Should we implement basic templates in Phase 1?
3. **Chat unlink behavior**: Should unlinking a chat from project show confirmation?
4. **Mobile layout preference**: Bottom tabs or swipeable tabs for project detail?
5. **File preview**: Which file types should support in-app preview vs download-only?

---

**End of Plan**
