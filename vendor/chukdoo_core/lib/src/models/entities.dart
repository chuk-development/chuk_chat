// Pure-Dart ports of the app's entity models.
//
// `toJson()` / `fromJson()` produce and read exactly the map the app keeps in
// Hive (lib/features/*/domain/models/*.dart). `fromRemote()` reads a server
// row the way the app's pull does (clear columns + decrypted payload);
// `remotePayload()` and `remoteRow()` produce what the app's upload writes.
//
// Fields are mutable on purpose: the tool layer edits a pulled entity in
// place, bumps `version`/`updatedAt` and writes it back.

import 'time_utils.dart';

/// Shared bookkeeping of every synced entity.
abstract class ChukdooEntity {
  String get id;
  String get userId;
  set userId(String value);

  /// The app's Hive/toJson map.
  Map<String, dynamic> toJson();

  /// What goes into `encrypted_payload` (before encryption).
  Map<String, dynamic> remotePayload();

  /// The row for `device_upsert`, given the encrypted payload.
  Map<String, dynamic> remoteRow(String encryptedPayload);

  /// Marks an edit: bumps version where the entity has one and sets
  /// updated_at to now, so the app's pull lets the server copy win.
  void touch(DateTime now);
}

// ── Todo ────────────────────────────────────────────────────────────────────

enum TodoStatus {
  todo('todo'),
  inProgress('in_progress'),
  done('done');

  const TodoStatus(this.value);
  final String value;

  static TodoStatus fromValue(String? value) => TodoStatus.values
      .firstWhere((s) => s.value == value, orElse: () => TodoStatus.todo);
}

class Todo implements ChukdooEntity {
  @override
  String id;
  @override
  String userId;
  String? projectId;
  String title;
  String? description;

  /// 1 (highest) .. 4 (none).
  int priority;

  /// Date only (midnight local).
  DateTime? dueDate;
  LocalTime? dueTime;

  /// Only meaningful with a [dueTime].
  LocalTime? endTime;
  bool isCompleted;
  DateTime? completedAt;
  String? recurrenceRule;
  int sortOrder;
  DateTime createdAt;
  DateTime updatedAt;
  String? encryptionContext;
  List<String> labelIds;
  DateTime? reminderAt;
  int version;
  TodoStatus status;
  bool isPinned;

  Todo({
    required this.id,
    required this.userId,
    this.projectId,
    required this.title,
    this.description,
    this.priority = 4,
    this.dueDate,
    this.dueTime,
    this.endTime,
    this.isCompleted = false,
    this.completedAt,
    this.recurrenceRule,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
    this.encryptionContext,
    List<String>? labelIds,
    this.reminderAt,
    this.version = 1,
    this.status = TodoStatus.todo,
    this.isPinned = false,
  }) : labelIds = labelIds ?? <String>[];

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'project_id': projectId,
        'title': title,
        'description': description,
        'priority': priority,
        'due_date': dueDate == null ? null : localIso(dueDate!),
        'due_time': dueTime?.toAppString(),
        'end_time': dueTime == null ? null : endTime?.toAppString(),
        'is_completed': isCompleted,
        'completed_at': completedAt == null ? null : localIso(completedAt!),
        'recurrence_rule': recurrenceRule,
        'sort_order': sortOrder,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
        'encryption_context': encryptionContext,
        'label_ids': labelIds,
        'reminder_at': reminderAt == null ? null : localIso(reminderAt!),
        'version': version,
        'status': status.value,
        'is_pinned': isPinned,
      };

  factory Todo.fromJson(Map<String, dynamic> json) {
    final dueTime = LocalTime.tryParse(json['due_time']);
    return Todo(
      id: json['id'] as String,
      userId: json['user_id'] as String? ?? '',
      projectId: json['project_id'] as String?,
      title: json['title'] as String? ?? '',
      description: json['description'] as String?,
      priority: _clampPriority(json['priority']),
      dueDate: tryParseWall(json['due_date']),
      dueTime: dueTime,
      endTime: dueTime == null ? null : LocalTime.tryParse(json['end_time']),
      isCompleted: json['is_completed'] as bool? ?? false,
      completedAt: tryParseWall(json['completed_at']),
      recurrenceRule: json['recurrence_rule'] as String?,
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      createdAt: tryParseWall(json['created_at']) ?? DateTime.now(),
      updatedAt: tryParseWall(json['updated_at']) ?? DateTime.now(),
      encryptionContext: json['encryption_context'] as String?,
      labelIds: (json['label_ids'] as List?)?.map((e) => e.toString()).toList(),
      reminderAt: tryParseWall(json['reminder_at']),
      version: (json['version'] as num?)?.toInt() ?? 1,
      status: TodoStatus.fromValue(json['status'] as String?),
      isPinned: json['is_pinned'] as bool? ?? false,
    );
  }

  /// The app pulls todos from the payload alone.
  factory Todo.fromRemote(
          Map<String, dynamic> row, Map<String, dynamic> payload) =>
      Todo.fromJson({'id': row['id'], 'user_id': row['user_id'], ...payload});

  @override
  Map<String, dynamic> remotePayload() => toJson();

  @override
  Map<String, dynamic> remoteRow(String encryptedPayload) => {
        'id': id,
        'user_id': userId,
        'encrypted_payload': encryptedPayload,
        'updated_at': localIso(DateTime.now()),
      };

  @override
  void touch(DateTime now) {
    version += 1;
    updatedAt = now;
  }

  /// Completion like the app's copyWith(isCompleted:/status:).
  void setCompleted(bool completed, DateTime now) {
    isCompleted = completed;
    if (completed) {
      status = TodoStatus.done;
      completedAt = now;
    } else {
      if (status == TodoStatus.done) status = TodoStatus.todo;
      completedAt = null;
    }
  }

  static int _clampPriority(Object? raw) {
    final v = (raw as num?)?.toInt() ?? 4;
    return (v < 1 || v > 4) ? 4 : v;
  }
}

// ── Project ─────────────────────────────────────────────────────────────────

class Project implements ChukdooEntity {
  @override
  String id;
  @override
  String userId;
  String name;
  String? description;
  int color;
  String? icon;
  bool isInbox;
  int sortOrder;
  DateTime createdAt;
  DateTime updatedAt;

  Project({
    required this.id,
    required this.userId,
    required this.name,
    this.description,
    this.color = 0xFF808080,
    this.icon,
    this.isInbox = false,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'name': name,
        'description': description,
        'color': color,
        'icon': icon,
        'is_inbox': isInbox,
        'sort_order': sortOrder,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
      };

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        userId: json['user_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String?,
        color: (json['color'] as num?)?.toInt() ?? 0xFF808080,
        icon: json['icon'] as String?,
        isInbox: json['is_inbox'] as bool? ?? false,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        createdAt: tryParseWall(json['created_at']) ?? DateTime.now(),
        updatedAt: tryParseWall(json['updated_at']) ?? DateTime.now(),
      );

  factory Project.fromRemote(
          Map<String, dynamic> row, Map<String, dynamic> payload) =>
      Project.fromJson({'id': row['id'], 'user_id': row['user_id'], ...payload});

  @override
  Map<String, dynamic> remotePayload() => toJson();

  @override
  Map<String, dynamic> remoteRow(String encryptedPayload) => {
        'id': id,
        'user_id': userId,
        'encrypted_payload': encryptedPayload,
        'updated_at': localIso(DateTime.now()),
      };

  @override
  void touch(DateTime now) => updatedAt = now;
}

// ── Calendar ────────────────────────────────────────────────────────────────

class Calendar implements ChukdooEntity {
  @override
  String id;
  @override
  String userId;
  String name;
  String? description;
  int color;
  bool isDefault;
  bool isVisible;
  int sortOrder;

  /// `general` or `birthdays`.
  String kind;
  DateTime createdAt;
  DateTime updatedAt;

  Calendar({
    required this.id,
    required this.userId,
    required this.name,
    this.description,
    this.color = 0xFF4285F4,
    this.isDefault = false,
    this.isVisible = true,
    this.sortOrder = 0,
    this.kind = 'general',
    required this.createdAt,
    required this.updatedAt,
  });

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'name': name,
        'description': description,
        'color': color,
        'is_default': isDefault,
        'is_visible': isVisible,
        'sort_order': sortOrder,
        'kind': kind,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
      };

  factory Calendar.fromJson(Map<String, dynamic> json) => Calendar(
        id: json['id'] as String,
        userId: json['user_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String?,
        color: (json['color'] as num?)?.toInt() ?? 0xFF4285F4,
        isDefault: json['is_default'] as bool? ?? false,
        isVisible: json['is_visible'] as bool? ?? true,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        kind: _kind(json['kind']),
        createdAt: tryParseWall(json['created_at']) ?? DateTime.now(),
        updatedAt: tryParseWall(json['updated_at']) ?? DateTime.now(),
      );

  /// Like `Calendar.fromSupabaseRow`: text from the payload, the rest from
  /// the clear columns.
  factory Calendar.fromRemote(
      Map<String, dynamic> row, Map<String, dynamic> payload) {
    return Calendar(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      name: payload['name'] as String? ?? '',
      description: payload['description'] as String?,
      color: parseHexColor(row['color'] as String?) ?? 0xFF4285F4,
      isDefault: row['is_default'] as bool? ?? false,
      isVisible: row['is_visible'] as bool? ?? true,
      sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
      kind: _kind(payload['kind']),
      createdAt: tryParseWall(row['created_at']) ?? DateTime.now(),
      updatedAt: tryParseWall(row['updated_at']) ?? DateTime.now(),
    );
  }

  @override
  Map<String, dynamic> remotePayload() => toJson();

  @override
  Map<String, dynamic> remoteRow(String encryptedPayload) => {
        'id': id,
        'user_id': userId,
        'encrypted_payload': encryptedPayload,
        'color': colorToRgbHex(color),
        'is_default': isDefault,
        'is_visible': isVisible,
        'sort_order': sortOrder,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
      };

  @override
  void touch(DateTime now) => updatedAt = now;

  static String _kind(Object? raw) => raw == 'birthdays' ? 'birthdays' : 'general';
}

// ── Calendar event ──────────────────────────────────────────────────────────

class CalendarEvent implements ChukdooEntity {
  @override
  String id;
  @override
  String userId;
  String? calendarId;
  String title;
  String? description;
  String? location;
  DateTime startTime;
  DateTime endTime;
  bool isAllDay;

  /// ARGB, 0 = use the calendar colour.
  int color;
  String? recurrenceRule;

  /// Set on an exception: the id of the recurring parent.
  String? recurrenceId;

  /// Set on an exception: the occurrence it replaces (local ISO).
  String? originalStartTime;
  List<int> reminderMinutes;
  int sortOrder;
  DateTime createdAt;
  DateTime updatedAt;
  String? encryptionContext;
  int version;

  CalendarEvent({
    required this.id,
    required this.userId,
    this.calendarId,
    required this.title,
    this.description,
    this.location,
    required this.startTime,
    required this.endTime,
    this.isAllDay = false,
    this.color = 0,
    this.recurrenceRule,
    this.recurrenceId,
    this.originalStartTime,
    List<int>? reminderMinutes,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
    this.encryptionContext,
    this.version = 1,
  }) : reminderMinutes = reminderMinutes ?? <int>[];

  bool get isRecurring => recurrenceRule != null && recurrenceRule!.isNotEmpty;
  bool get isException => recurrenceId != null;

  /// The app marks a deleted single occurrence with this title.
  bool get isDeletedOccurrence => isException && title == '__DELETED__';
  Duration get duration => endTime.difference(startTime);

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'calendar_id': calendarId,
        'title': title,
        'description': description,
        'location': location,
        'start_time': localIso(startTime),
        'end_time': localIso(endTime),
        'is_all_day': isAllDay,
        'color': color,
        'recurrence_rule': recurrenceRule,
        'recurrence_id': recurrenceId,
        'original_start_time': originalStartTime,
        'reminder_minutes': reminderMinutes,
        'sort_order': sortOrder,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
        'encryption_context': encryptionContext,
        'version': version,
      };

  factory CalendarEvent.fromJson(Map<String, dynamic> json) => CalendarEvent(
        id: json['id'] as String,
        userId: json['user_id'] as String? ?? '',
        calendarId: json['calendar_id'] as String?,
        title: json['title'] as String? ?? '',
        description: json['description'] as String?,
        location: json['location'] as String?,
        startTime: parseWall(json['start_time'] as String),
        endTime: parseWall(json['end_time'] as String),
        isAllDay: json['is_all_day'] as bool? ?? false,
        color: (json['color'] as num?)?.toInt() ?? 0,
        recurrenceRule: json['recurrence_rule'] as String?,
        recurrenceId: json['recurrence_id'] as String?,
        originalStartTime: json['original_start_time'] as String?,
        reminderMinutes: (json['reminder_minutes'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList(),
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        createdAt: tryParseWall(json['created_at']) ?? DateTime.now(),
        updatedAt: tryParseWall(json['updated_at']) ?? DateTime.now(),
        encryptionContext: json['encryption_context'] as String?,
        version: (json['version'] as num?)?.toInt() ?? 1,
      );

  /// Like `CalendarEvent.fromSupabaseRow`: title/description/location from
  /// the payload, everything else from the clear columns (payload as
  /// fallback for rows written by the old payload-only upload).
  factory CalendarEvent.fromRemote(
      Map<String, dynamic> row, Map<String, dynamic> payload) {
    T? pick<T>(String key) => (row[key] ?? payload[key]) as T?;
    final colorRaw = row['color'];
    final original = row['original_start_time'] ?? payload['original_start_time'];
    return CalendarEvent(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      calendarId: pick<String>('calendar_id'),
      title: payload['title'] as String? ?? '',
      description: payload['description'] as String?,
      location: payload['location'] as String?,
      startTime: parseWall(pick<String>('start_time')!),
      endTime: parseWall(pick<String>('end_time')!),
      isAllDay: pick<bool>('is_all_day') ?? false,
      color: colorRaw is String
          ? (int.tryParse(colorRaw) ?? 0)
          : ((payload['color'] as num?)?.toInt() ?? 0),
      recurrenceRule: pick<String>('recurrence_rule'),
      recurrenceId: pick<String>('recurrence_id'),
      originalStartTime: original is String
          ? localIso(parseWall(original))
          : null,
      reminderMinutes: ((row['reminder_minutes'] ?? payload['reminder_minutes'])
              as List?)
          ?.map((e) => (e as num).toInt())
          .toList(),
      sortOrder: (pick<num>('sort_order'))?.toInt() ?? 0,
      version: (pick<num>('version'))?.toInt() ?? 1,
      encryptionContext: pick<String>('encryption_context'),
      createdAt: tryParseWall(row['created_at']) ?? DateTime.now(),
      updatedAt: tryParseWall(row['updated_at']) ?? DateTime.now(),
    );
  }

  @override
  Map<String, dynamic> remotePayload() => toJson();

  @override
  Map<String, dynamic> remoteRow(String encryptedPayload) => {
        'id': id,
        'user_id': userId,
        'calendar_id': calendarId,
        'encrypted_payload': encryptedPayload,
        'start_time': localIso(startTime),
        'end_time': localIso(endTime),
        'is_all_day': isAllDay,
        'color': color != 0 ? color.toString() : null,
        'recurrence_rule': recurrenceRule,
        'recurrence_id': recurrenceId,
        'original_start_time': originalStartTime,
        'reminder_minutes': reminderMinutes,
        'sort_order': sortOrder,
        'version': version,
        'encryption_context': encryptionContext,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
      };

  @override
  void touch(DateTime now) {
    version += 1;
    updatedAt = now;
  }
}

// ── Habit ───────────────────────────────────────────────────────────────────

class Habit implements ChukdooEntity {
  @override
  String id;
  @override
  String userId;
  String name;
  String? description;
  int color;

  /// `daily` or `weekly`.
  String frequency;

  /// `yyyy-MM-dd` strings.
  List<String> completions;
  int streak;
  int sortOrder;
  DateTime createdAt;
  DateTime updatedAt;
  String? encryptionContext;
  int version;

  Habit({
    required this.id,
    required this.userId,
    required this.name,
    this.description,
    this.color = 0xFF00BFA5,
    this.frequency = 'daily',
    List<String>? completions,
    this.streak = 0,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
    this.encryptionContext,
    this.version = 1,
  }) : completions = completions ?? <String>[];

  bool isCompletedOn(DateTime date) => completions.contains(dateKey(date));

  /// Port of `Habit.calculateStreak()`.
  int calculateStreak([DateTime? now]) {
    if (completions.isEmpty) return 0;
    final completed = completions.toSet();
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    if (!completed.contains(dateKey(today)) &&
        !completed.contains(dateKey(yesterday))) {
      return 0;
    }
    var streak = 0;
    var check = completed.contains(dateKey(today)) ? today : yesterday;
    while (completed.contains(dateKey(check))) {
      streak++;
      check = DateTime(check.year, check.month, check.day - 1);
    }
    return streak;
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'name': name,
        'description': description,
        'color': color,
        'frequency': frequency,
        'completions': completions,
        'streak': streak,
        'sort_order': sortOrder,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
        'encryption_context': encryptionContext,
        'version': version,
      };

  factory Habit.fromJson(Map<String, dynamic> json) {
    final created = tryParseWall(json['created_at']) ?? DateTime.now();
    return Habit(
      id: json['id'] as String,
      userId: json['user_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      color: (json['color'] as num?)?.toInt() ?? 0xFF00BFA5,
      frequency: json['frequency'] as String? ?? 'daily',
      completions:
          (json['completions'] as List?)?.map((e) => e.toString()).toList(),
      streak: (json['streak'] as num?)?.toInt() ?? 0,
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      createdAt: created,
      updatedAt: tryParseWall(json['updated_at']) ?? created,
      encryptionContext: json['encryption_context'] as String?,
      version: (json['version'] as num?)?.toInt() ?? 1,
    );
  }

  /// Like `Habit.fromSupabaseRow`: name/description from the payload, the
  /// rest from the clear columns.
  factory Habit.fromRemote(
      Map<String, dynamic> row, Map<String, dynamic> payload) {
    return Habit(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      name: payload['name'] as String? ?? '',
      description: payload['description'] as String?,
      color: parseHexColor(row['color'] as String?) ?? 0xFF00BFA5,
      frequency: row['frequency'] as String? ?? 'daily',
      completions:
          (row['completions'] as List?)?.map((e) => e.toString()).toList(),
      streak: (row['streak'] as num?)?.toInt() ?? 0,
      sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
      version: (row['version'] as num?)?.toInt() ?? 1,
      encryptionContext: row['encryption_context'] as String?,
      createdAt: tryParseWall(row['created_at']) ?? DateTime.now(),
      updatedAt: tryParseWall(row['updated_at']) ?? DateTime.now(),
    );
  }

  @override
  Map<String, dynamic> remotePayload() => toJson();

  @override
  Map<String, dynamic> remoteRow(String encryptedPayload) => {
        'id': id,
        'user_id': userId,
        'encrypted_payload': encryptedPayload,
        'color': colorToArgbHex(color),
        'frequency': frequency,
        'completions': completions,
        'streak': streak,
        'sort_order': sortOrder,
        'version': version,
        'encryption_context': encryptionContext,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
      };

  @override
  void touch(DateTime now) {
    version += 1;
    updatedAt = now;
  }
}

// ── Note ────────────────────────────────────────────────────────────────────

class Note implements ChukdooEntity {
  @override
  String id;
  @override
  String userId;
  String title;

  /// Markdown.
  String content;
  int? color;
  String? folderId;
  int sortOrder;
  bool isPinned;
  DateTime createdAt;
  DateTime updatedAt;
  int version;

  Note({
    required this.id,
    required this.userId,
    this.title = '',
    this.content = '',
    this.color,
    this.folderId,
    this.sortOrder = 0,
    this.isPinned = false,
    required this.createdAt,
    required this.updatedAt,
    this.version = 1,
  });

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'title': title,
        'content': content,
        'color': color,
        'folder_id': folderId,
        'sort_order': sortOrder,
        'is_pinned': isPinned,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
        'version': version,
      };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String,
        userId: json['user_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        color: (json['color'] as num?)?.toInt(),
        folderId: json['folder_id'] as String?,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        isPinned: json['is_pinned'] as bool? ?? false,
        createdAt: tryParseWall(json['created_at']) ?? DateTime.now(),
        updatedAt: tryParseWall(json['updated_at']) ?? DateTime.now(),
        version: (json['version'] as num?)?.toInt() ?? 1,
      );

  factory Note.fromRemote(
      Map<String, dynamic> row, Map<String, dynamic> payload) {
    return Note(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      title: payload['title'] as String? ?? '',
      content: payload['content'] as String? ?? '',
      folderId: payload['folder_id'] as String?,
      color: parseHexColor(row['color'] as String?),
      sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
      isPinned: row['is_pinned'] as bool? ?? false,
      createdAt: tryParseWall(row['created_at']) ?? DateTime.now(),
      updatedAt: tryParseWall(row['updated_at']) ?? DateTime.now(),
      version: (row['version'] as num?)?.toInt() ?? 1,
    );
  }

  /// `Note.toEncryptedPayload()`.
  @override
  Map<String, dynamic> remotePayload() =>
      {'title': title, 'content': content, 'folder_id': folderId};

  @override
  Map<String, dynamic> remoteRow(String encryptedPayload) => {
        'id': id,
        'user_id': userId,
        'encrypted_payload': encryptedPayload,
        'color': color == null ? null : colorToArgbHex(color!),
        'sort_order': sortOrder,
        'is_pinned': isPinned,
        'version': version,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
      };

  @override
  void touch(DateTime now) {
    version += 1;
    updatedAt = now;
  }
}

// ── Note folder ─────────────────────────────────────────────────────────────

class NoteFolder implements ChukdooEntity {
  static const int defaultColor = 0xFF7C82E0;

  @override
  String id;
  @override
  String userId;
  String name;
  int color;
  int sortOrder;
  DateTime createdAt;
  DateTime updatedAt;
  int version;

  NoteFolder({
    required this.id,
    required this.userId,
    this.name = '',
    this.color = defaultColor,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
    this.version = 1,
  });

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'name': name,
        'color': color,
        'sort_order': sortOrder,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
        'version': version,
      };

  factory NoteFolder.fromJson(Map<String, dynamic> json) => NoteFolder(
        id: json['id'] as String,
        userId: json['user_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        color: (json['color'] as num?)?.toInt() ?? defaultColor,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        createdAt: tryParseWall(json['created_at']) ?? DateTime.now(),
        updatedAt: tryParseWall(json['updated_at']) ?? DateTime.now(),
        version: (json['version'] as num?)?.toInt() ?? 1,
      );

  factory NoteFolder.fromRemote(
      Map<String, dynamic> row, Map<String, dynamic> payload) {
    return NoteFolder(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      name: payload['name'] as String? ?? '',
      color: parseHexColor(row['color'] as String?) ?? defaultColor,
      sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
      createdAt: tryParseWall(row['created_at']) ?? DateTime.now(),
      updatedAt: tryParseWall(row['updated_at']) ?? DateTime.now(),
      version: (row['version'] as num?)?.toInt() ?? 1,
    );
  }

  @override
  Map<String, dynamic> remotePayload() => {'name': name};

  @override
  Map<String, dynamic> remoteRow(String encryptedPayload) => {
        'id': id,
        'user_id': userId,
        'encrypted_payload': encryptedPayload,
        'color': colorToArgbHex(color),
        'sort_order': sortOrder,
        'version': version,
        'created_at': localIso(createdAt),
        'updated_at': localIso(updatedAt),
      };

  @override
  void touch(DateTime now) {
    version += 1;
    updatedAt = now;
  }
}
