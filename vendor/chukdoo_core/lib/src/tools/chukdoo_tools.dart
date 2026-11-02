import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../credentials.dart';
import '../models/entities.dart';
import '../models/occurrences.dart';
import '../models/rrule.dart';
import '../models/time_utils.dart';
import '../store.dart';
import 'tool_args.dart';

/// One tool as any transport (MCP, chuk_chat's tool calling) presents it.
class ChukdooToolSpec {
  final String name;
  final String description;

  /// JSON schema of the arguments object.
  final Map<String, dynamic> inputSchema;

  /// True if the tool only reads.
  final bool readOnly;

  const ChukdooToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.readOnly = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

typedef _Handler = Future<Map<String, dynamic>> Function(ToolArgs args);

/// Transport-agnostic tool layer over a chukdoo account.
///
/// ```dart
/// final tools = ChukdooTools.fromCredentials(creds);
/// for (final spec in tools.specs) { ... register spec.name ... }
/// final result = await tools.callTool('list_todos', {'filter': 'today'});
/// ```
///
/// All dates and times in and out are LOCAL wall-clock values of the machine
/// running this code (`YYYY-MM-DD`, `YYYY-MM-DDTHH:mm`, `HH:mm`).
/// [callTool] throws [ChukdooToolError] for bad input (show it to the model)
/// and [ChukdooApiException] for server errors.
class ChukdooTools {
  final ChukdooStore store;
  late final Map<String, (ChukdooToolSpec, _Handler)> _tools = _build();

  ChukdooTools(this.store);

  factory ChukdooTools.fromCredentials(
    ChukdooCredentials credentials, {
    http.Client? httpClient,
    DateTime Function()? clock,
  }) =>
      ChukdooTools(ChukdooStore(
        credentials: credentials,
        httpClient: httpClient,
        clock: clock,
      ));

  List<ChukdooToolSpec> get specs => [for (final t in _tools.values) t.$1];

  Future<Map<String, dynamic>> callTool(
      String name, Map<String, dynamic>? arguments) async {
    final tool = _tools[name];
    if (tool == null) throw ChukdooToolError('Unknown tool "$name".');
    return tool.$2(ToolArgs(arguments, store.now()));
  }

  void close() => store.close();

  // ── Registry ──────────────────────────────────────────────────────────────

  Map<String, (ChukdooToolSpec, _Handler)> _build() {
    final m = <String, (ChukdooToolSpec, _Handler)>{};
    void add(String name, String description, Map<String, dynamic> props,
        _Handler handler,
        {List<String> required = const [], bool readOnly = false}) {
      m[name] = (
        ChukdooToolSpec(
          name: name,
          description: description,
          readOnly: readOnly,
          inputSchema: {
            'type': 'object',
            'properties': props,
            if (required.isNotEmpty) 'required': required,
          },
        ),
        handler,
      );
    }

    // Overview
    add('get_overview',
        'One-shot summary of a day (default today): events, tasks due that day, '
            'overdue tasks and habits with their state. Start here for "what is on today".',
        {'date': _dateProp('Day to summarize (default today).')},
        _getOverview,
        readOnly: true);

    // Todos
    add('list_todos',
        'List tasks. filter: "open" (default, all not completed), "today" (due today), '
            '"overdue", "upcoming" (due in the next `days` days, default 7), "no_date", '
            '"completed", "all". Optional project (name or id), label and search text.',
        {
          'filter': {
            'type': 'string',
            'enum': ['open', 'today', 'overdue', 'upcoming', 'no_date', 'completed', 'all'],
          },
          'days': {'type': 'integer', 'description': 'Window for "upcoming" (default 7).'},
          'project': {'type': 'string', 'description': 'Project name or id. "inbox" = tasks without project.'},
          'label': {'type': 'string'},
          'search': {'type': 'string', 'description': 'Case-insensitive text in title or description.'},
          'limit': {'type': 'integer', 'description': 'Max results (default 100).'},
        },
        _listTodos,
        readOnly: true);
    add('create_todo',
        'Create a task. Priority 1 (highest) to 4 (none, default). end_time needs due_time.',
        _todoProps(),
        _createTodo,
        required: ['title']);
    add('update_todo',
        'Change a task. Only given fields change; pass null to clear due_date, due_time, '
            'end_time, description or project.',
        {'id': _idProp('Task id.'), ..._todoProps(), 'status': {'type': 'string', 'enum': ['todo', 'in_progress', 'done']}},
        _updateTodo,
        required: ['id']);
    add('complete_todo', 'Mark a task as done.', {'id': _idProp('Task id.')},
        (a) => _setTodoCompleted(a, true),
        required: ['id']);
    add('reopen_todo', 'Mark a done task as not done again.', {'id': _idProp('Task id.')},
        (a) => _setTodoCompleted(a, false),
        required: ['id']);
    add('delete_todo', 'Delete a task permanently.', {'id': _idProp('Task id.')},
        (a) => _delete(a, ChukdooTable.todos, 'task'),
        required: ['id']);

    // Projects
    add('list_projects', 'List projects (task lists) with their number of open tasks.', {},
        _listProjects,
        readOnly: true);
    add('create_project', 'Create a project (task list).', {
      'name': {'type': 'string'},
      'description': {'type': 'string'},
      'color': _colorProp(),
    }, _createProject, required: ['name']);

    // Calendar
    add('list_calendars', 'List calendars.', {}, _listCalendars, readOnly: true);
    add('list_events',
        'List calendar events between from and to (local; default: today for 7 days). '
            'Recurring events are expanded into single occurrences with occurrence_start.',
        {
          'from': _dateTimeProp('Start of the range (date or date-time).'),
          'to': _dateTimeProp('End of the range, exclusive (date or date-time).'),
          'calendar': {'type': 'string', 'description': 'Calendar name or id.'},
          'search': {'type': 'string'},
        },
        _listEvents,
        readOnly: true);
    add('create_event',
        'Create a calendar event. Give start and end (or duration_minutes, default 60). '
            'all_day events take dates. recurrence_rule is an RRULE like "FREQ=WEEKLY;BYDAY=MO,WE".',
        _eventProps(),
        _createEvent,
        required: ['title', 'start']);
    add('update_event',
        'Change, move or resize an event. Only given fields change. Moving with only `start` '
            'keeps the duration. For one occurrence of a recurring event pass occurrence_start '
            '(from list_events); otherwise the whole series changes.',
        {
          'id': _idProp('Event id.'),
          'occurrence_start': _dateTimeProp('Edit only this occurrence of a recurring event.'),
          ..._eventProps(),
        },
        _updateEvent,
        required: ['id']);
    add('delete_event',
        'Delete an event. For one occurrence of a recurring event pass occurrence_start; '
            'otherwise the whole series is deleted.',
        {
          'id': _idProp('Event id.'),
          'occurrence_start': _dateTimeProp('Delete only this occurrence.'),
        },
        _deleteEvent,
        required: ['id']);

    // Notes
    add('list_notes', 'List notes (title, folder, preview), pinned first, newest first.', {
      'folder': {'type': 'string', 'description': 'Folder name or id; "none" = notes without folder.'},
      'limit': {'type': 'integer', 'description': 'Max results (default 50).'},
    }, _listNotes, readOnly: true);
    add('search_notes', 'Full-text search in note titles and content.', {
      'query': {'type': 'string'},
      'limit': {'type': 'integer'},
    }, _searchNotes, required: ['query'], readOnly: true);
    add('get_note', 'Get one note with its full markdown content.', {'id': _idProp('Note id.')},
        _getNote,
        required: ['id'], readOnly: true);
    add('create_note', 'Create a note. content is markdown.', {
      'title': {'type': 'string'},
      'content': {'type': 'string'},
      'folder': {'type': 'string', 'description': 'Folder name or id.'},
      'pinned': {'type': 'boolean'},
    }, _createNote);
    add('update_note',
        'Change a note. content replaces the body; append adds text at the end instead.', {
      'id': _idProp('Note id.'),
      'title': {'type': 'string'},
      'content': {'type': 'string'},
      'append': {'type': 'string'},
      'folder': {'type': ['string', 'null'], 'description': 'Folder name or id, null = no folder.'},
      'pinned': {'type': 'boolean'},
    }, _updateNote, required: ['id']);
    add('delete_note', 'Delete a note permanently.', {'id': _idProp('Note id.')},
        (a) => _delete(a, ChukdooTable.notes, 'note'),
        required: ['id']);
    add('list_note_folders', 'List note folders with their number of notes.', {},
        _listNoteFolders,
        readOnly: true);

    // Habits
    add('list_habits', 'List habits with their state on a day (default today), streak and the last 7 days.', {
      'date': _dateProp('Reference day (default today).'),
    }, _listHabits, readOnly: true);
    add('create_habit', 'Create a habit.', {
      'name': {'type': 'string'},
      'description': {'type': 'string'},
      'frequency': {'type': 'string', 'enum': ['daily', 'weekly']},
      'color': _colorProp(),
    }, _createHabit, required: ['name']);
    add('check_habit', 'Mark a habit as done on a day (default today).', {
      'id': _idProp('Habit id.'),
      'date': _dateProp('Day (default today).'),
    }, (a) => _setHabit(a, true), required: ['id']);
    add('uncheck_habit', 'Remove the done mark of a habit on a day (default today).', {
      'id': _idProp('Habit id.'),
      'date': _dateProp('Day (default today).'),
    }, (a) => _setHabit(a, false), required: ['id']);
    add('delete_habit', 'Delete a habit and its history permanently.', {'id': _idProp('Habit id.')},
        (a) => _delete(a, ChukdooTable.habits, 'habit'),
        required: ['id']);

    return m;
  }

  static Map<String, dynamic> _idProp(String d) => {'type': 'string', 'description': d};
  static Map<String, dynamic> _dateProp(String d) =>
      {'type': 'string', 'description': '$d Format YYYY-MM-DD, or today/tomorrow.'};
  static Map<String, dynamic> _dateTimeProp(String d) =>
      {'type': 'string', 'description': '$d Local time, format YYYY-MM-DDTHH:mm.'};
  static Map<String, dynamic> _colorProp() =>
      {'type': 'string', 'description': 'Hex colour like #4285F4.'};

  static Map<String, dynamic> _todoProps() => {
        'title': {'type': 'string'},
        'description': {'type': ['string', 'null']},
        'due_date': {'type': ['string', 'null'], 'description': 'YYYY-MM-DD, or today/tomorrow.'},
        'due_time': {'type': ['string', 'null'], 'description': 'HH:mm (needs a due_date).'},
        'end_time': {'type': ['string', 'null'], 'description': 'HH:mm, end of a time block.'},
        'priority': {'type': 'integer', 'minimum': 1, 'maximum': 4},
        'project': {'type': ['string', 'null'], 'description': 'Project name or id; null = no project.'},
        'labels': {'type': 'array', 'items': {'type': 'string'}},
        'pinned': {'type': 'boolean'},
      };

  static Map<String, dynamic> _eventProps() => {
        'title': {'type': 'string'},
        'start': {'type': 'string', 'description': 'YYYY-MM-DDTHH:mm local (date only for all_day).'},
        'end': {'type': 'string', 'description': 'YYYY-MM-DDTHH:mm local (last day for all_day).'},
        'duration_minutes': {'type': 'integer'},
        'all_day': {'type': 'boolean'},
        'calendar': {'type': 'string', 'description': 'Calendar name or id (default: the default calendar).'},
        'description': {'type': ['string', 'null']},
        'location': {'type': ['string', 'null']},
        'recurrence_rule': {'type': ['string', 'null'], 'description': 'RRULE, e.g. FREQ=DAILY;COUNT=5. null removes it.'},
        'reminder_minutes': {'type': 'array', 'items': {'type': 'integer'}, 'description': 'Minutes before start.'},
        'color': {'type': ['string', 'null'], 'description': 'Hex colour, null = calendar colour.'},
      };

  // ── Lookups ───────────────────────────────────────────────────────────────

  Future<T> _byId<T extends ChukdooEntity>(
      Future<List<T>> Function() load, String id, String what) async {
    final items = await load();
    final exact = items.where((e) => e.id == id).toList();
    if (exact.isNotEmpty) return exact.first;
    // Allow a unique id prefix (models sometimes shorten ids).
    if (id.length >= 6) {
      final prefixed = items.where((e) => e.id.startsWith(id)).toList();
      if (prefixed.length == 1) return prefixed.first;
    }
    throw ChukdooToolError('No $what with id "$id".');
  }

  /// null for "inbox"/"none"; throws if unknown.
  Future<Project?> _resolveProject(String input) async {
    final lower = input.toLowerCase();
    if (lower == 'inbox' || lower == 'none' || lower == 'no project') return null;
    final projects = await store.projects();
    for (final p in projects) {
      if (p.id == input || p.name.toLowerCase() == lower) return p;
    }
    final names = projects.map((p) => p.name).join(', ');
    throw ChukdooToolError('Unknown project "$input". Existing projects: ${names.isEmpty ? '(none)' : names}. '
        'Use create_project first if needed.');
  }

  Future<Calendar> _resolveCalendar(String input) async {
    final calendars = await store.calendars();
    final lower = input.toLowerCase();
    for (final c in calendars) {
      if (c.id == input || c.name.toLowerCase() == lower) return c;
    }
    throw ChukdooToolError('Unknown calendar "$input". Existing calendars: '
        '${calendars.map((c) => c.name).join(', ')}.');
  }

  Future<Calendar?> _defaultCalendar() async {
    final calendars = await store.calendars();
    if (calendars.isEmpty) return null;
    final defaults = calendars.where((c) => c.isDefault && c.kind == 'general');
    if (defaults.isNotEmpty) return defaults.first;
    final general = calendars.where((c) => c.kind == 'general').toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return general.isNotEmpty ? general.first : calendars.first;
  }

  Future<NoteFolder?> _resolveFolder(String? input) async {
    if (input == null) return null;
    final lower = input.toLowerCase();
    if (lower == 'none' || lower == 'no folder') return null;
    final folders = await store.noteFolders();
    for (final f in folders) {
      if (f.id == input || f.name.toLowerCase() == lower) return f;
    }
    throw ChukdooToolError('Unknown folder "$input". Existing folders: '
        '${folders.map((f) => f.name).join(', ')}.');
  }

  // ── Output shapes ─────────────────────────────────────────────────────────

  Map<String, dynamic> _todoOut(Todo t, Map<String, Project> projects, DateTime today) {
    final due = t.dueDate == null ? null : dateOnly(t.dueDate!);
    return {
      'id': t.id,
      'title': t.title,
      if (t.description != null && t.description!.isNotEmpty) 'description': t.description,
      'priority': t.priority,
      'due_date': due == null ? null : dateKey(due),
      if (t.dueTime != null) 'due_time': t.dueTime!.toDisplay(),
      if (t.endTime != null) 'end_time': t.endTime!.toDisplay(),
      'project': t.projectId == null
          ? null
          : (projects[t.projectId]?.name ?? t.projectId),
      if (t.labelIds.isNotEmpty) 'labels': t.labelIds,
      'completed': t.isCompleted,
      if (t.completedAt != null) 'completed_at': fmtDateTime(t.completedAt!),
      'status': t.status.value,
      if (!t.isCompleted && due != null && due.isBefore(today)) 'overdue': true,
      if (t.recurrenceRule != null) 'recurrence_rule': t.recurrenceRule,
      if (t.isPinned) 'pinned': true,
    };
  }

  Map<String, dynamic> _eventOut(EventOccurrence o, Map<String, Calendar> calendars) {
    final e = o.event;
    final cal = e.calendarId == null ? null : calendars[e.calendarId];
    return {
      'id': e.isException ? e.recurrenceId : e.id,
      if (e.isException) 'exception_id': e.id,
      'title': e.title,
      'start': e.isAllDay ? dateKey(o.start) : fmtDateTime(o.start),
      'end': e.isAllDay ? dateKey(o.end) : fmtDateTime(o.end),
      'all_day': e.isAllDay,
      'calendar': cal?.name ?? e.calendarId,
      if (e.location != null && e.location!.isNotEmpty) 'location': e.location,
      if (e.description != null && e.description!.isNotEmpty) 'description': e.description,
      if (e.isRecurring) 'recurrence_rule': e.recurrenceRule,
      if (o.isRecurringInstance || e.isException)
        'occurrence_start': fmtDateTime(e.isException
            ? (tryParseWall(e.originalStartTime) ?? o.start)
            : o.start),
      if (e.reminderMinutes.isNotEmpty) 'reminder_minutes': e.reminderMinutes,
    };
  }

  Map<String, dynamic> _habitOut(Habit h, DateTime day) {
    final last7 = <String, bool>{};
    for (var i = 6; i >= 0; i--) {
      final d = DateTime(day.year, day.month, day.day - i);
      last7[dateKey(d)] = h.isCompletedOn(d);
    }
    return {
      'id': h.id,
      'name': h.name,
      if (h.description != null && h.description!.isNotEmpty) 'description': h.description,
      'frequency': h.frequency,
      'done': h.isCompletedOn(day),
      'streak': h.calculateStreak(store.now()),
      'last_7_days': last7,
      'total_completions': h.completions.length,
    };
  }

  Map<String, dynamic> _noteOut(Note n, Map<String, NoteFolder> folders, {bool full = false}) {
    final preview = n.content.length > 160 ? '${n.content.substring(0, 160)}...' : n.content;
    return {
      'id': n.id,
      'title': n.title,
      'folder': n.folderId == null ? null : (folders[n.folderId]?.name ?? n.folderId),
      if (n.isPinned) 'pinned': true,
      'updated_at': fmtDateTime(n.updatedAt),
      if (full) 'content': n.content else 'preview': preview,
    };
  }

  // ── Handlers: overview ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getOverview(ToolArgs a) async {
    final now = store.now();
    final day = a.date('date') ?? dateOnly(now);
    final today = dateOnly(now);
    final results = await Future.wait([
      store.todos(), store.projects(), store.events(), store.calendars(), store.habits(),
    ]);
    final todos = results[0] as List<Todo>;
    final projects = {for (final p in results[1] as List<Project>) p.id: p};
    final events = results[2] as List<CalendarEvent>;
    final calendars = {for (final c in results[3] as List<Calendar>) c.id: c};
    final habits = results[4] as List<Habit>;

    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    final occ = expandEvents(_visibleEvents(events, calendars), day, dayEnd);
    final due = todos.where((t) => !t.isCompleted && t.dueDate != null && _sameDay(t.dueDate!, day)).toList()
      ..sort(_todoOrder);
    final overdue = todos
        .where((t) => !t.isCompleted && t.dueDate != null && dateOnly(t.dueDate!).isBefore(day))
        .toList()
      ..sort(_todoOrder);

    return {
      'date': dateKey(day),
      'weekday': weekdayName(day),
      'now': fmtDateTime(now),
      'events': [for (final o in occ) _eventOut(o, calendars)],
      'todos_due': [for (final t in due) _todoOut(t, projects, today)],
      'todos_overdue': [for (final t in overdue) _todoOut(t, projects, today)],
      'habits': [for (final h in habits) _habitOut(h, day)],
      ..._skippedNote(),
    };
  }

  // ── Handlers: todos ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listTodos(ToolArgs a) async {
    final now = store.now();
    final today = dateOnly(now);
    final filter = a.string('filter') ?? 'open';
    final days = a.integer('days') ?? 7;
    final limit = a.integer('limit') ?? 100;
    final search = a.string('search')?.toLowerCase();
    final label = a.string('label')?.toLowerCase();
    final projectInput = a.string('project');

    final todos = await store.todos();
    final projectList = await store.projects();
    final projects = {for (final p in projectList) p.id: p};
    String? projectId;
    var filterByProject = false;
    if (projectInput != null) {
      filterByProject = true;
      projectId = (await _resolveProject(projectInput))?.id;
    }

    final horizon = DateTime(today.year, today.month, today.day + days + 1);
    bool keep(Todo t) {
      final due = t.dueDate == null ? null : dateOnly(t.dueDate!);
      switch (filter) {
        case 'open':
          if (t.isCompleted) return false;
        case 'today':
          if (t.isCompleted || due == null || due != today) return false;
        case 'overdue':
          if (t.isCompleted || due == null || !due.isBefore(today)) return false;
        case 'upcoming':
          if (t.isCompleted || due == null || due.isBefore(today) || !due.isBefore(horizon)) return false;
        case 'no_date':
          if (t.isCompleted || due != null) return false;
        case 'completed':
          if (!t.isCompleted) return false;
        case 'all':
          break;
        default:
          throw ChukdooToolError('Unknown filter "$filter".');
      }
      if (filterByProject && t.projectId != projectId) return false;
      if (label != null && !t.labelIds.any((l) => l.toLowerCase() == label)) return false;
      if (search != null &&
          !t.title.toLowerCase().contains(search) &&
          !(t.description?.toLowerCase().contains(search) ?? false)) {
        return false;
      }
      return true;
    }

    final list = todos.where(keep).toList();
    if (filter == 'completed') {
      list.sort((x, y) => (y.completedAt ?? y.updatedAt).compareTo(x.completedAt ?? x.updatedAt));
    } else {
      list.sort(_todoOrder);
    }
    return {
      'filter': filter,
      'today': dateKey(today),
      'count': list.length,
      'todos': [for (final t in list.take(limit)) _todoOut(t, projects, today)],
      if (list.length > limit) 'truncated': true,
      ..._skippedNote(),
    };
  }

  Future<Map<String, dynamic>> _createTodo(ToolArgs a) async {
    final now = store.now();
    final todo = Todo(
      id: store.newId(),
      userId: store.userId,
      title: a.requireString('title'),
      createdAt: now,
      updatedAt: now,
    );
    await _applyTodoFields(todo, a);
    await store.save(ChukdooTable.todos, todo);
    final projects = {for (final p in await store.projects()) p.id: p};
    return {'created': _todoOut(todo, projects, dateOnly(now))};
  }

  Future<Map<String, dynamic>> _updateTodo(ToolArgs a) async {
    final todo = await _byId(store.todos, a.requireString('id'), 'task');
    final now = store.now();
    if (a.has('title')) todo.title = a.requireString('title');
    await _applyTodoFields(todo, a);
    final status = a.string('status');
    if (status != null) {
      final s = TodoStatus.fromValue(status);
      if (s == TodoStatus.done) {
        if (!todo.isCompleted) todo.setCompleted(true, now);
      } else {
        if (todo.isCompleted) todo.setCompleted(false, now);
        todo.status = s;
      }
    }
    todo.touch(now);
    await store.save(ChukdooTable.todos, todo);
    final projects = {for (final p in await store.projects()) p.id: p};
    return {'updated': _todoOut(todo, projects, dateOnly(now))};
  }

  Future<void> _applyTodoFields(Todo todo, ToolArgs a) async {
    if (a.has('description')) todo.description = a.text('description');
    if (a.has('due_date')) {
      todo.dueDate = a.date('due_date');
      if (todo.dueDate == null) {
        todo.dueTime = null;
        todo.endTime = null;
      }
    }
    if (a.has('due_time')) {
      todo.dueTime = a.time('due_time');
      if (todo.dueTime != null && todo.dueDate == null) {
        todo.dueDate = dateOnly(store.now());
      }
      if (todo.dueTime == null) todo.endTime = null;
    }
    if (a.has('end_time')) {
      final end = a.time('end_time');
      if (end != null && todo.dueTime == null) {
        throw const ChukdooToolError('end_time needs a due_time.');
      }
      if (end != null && end.compareTo(todo.dueTime!) <= 0) {
        throw const ChukdooToolError('end_time must be after due_time.');
      }
      todo.endTime = end;
    }
    if (a.has('priority')) {
      final p = a.integer('priority') ?? 4;
      if (p < 1 || p > 4) throw const ChukdooToolError('priority must be 1..4.');
      todo.priority = p;
    }
    if (a.has('project')) {
      final input = a.string('project');
      todo.projectId = input == null ? null : (await _resolveProject(input))?.id;
    }
    if (a.has('labels')) todo.labelIds = a.stringList('labels') ?? [];
    if (a.has('pinned')) todo.isPinned = a.boolean('pinned') ?? false;
  }

  Future<Map<String, dynamic>> _setTodoCompleted(ToolArgs a, bool done) async {
    final todo = await _byId(store.todos, a.requireString('id'), 'task');
    final now = store.now();
    if (todo.isCompleted != done) {
      todo.setCompleted(done, now);
      todo.touch(now);
      await store.save(ChukdooTable.todos, todo);
    }
    final projects = {for (final p in await store.projects()) p.id: p};
    return {done ? 'completed' : 'reopened': _todoOut(todo, projects, dateOnly(now))};
  }

  Future<Map<String, dynamic>> _delete(ToolArgs a, ChukdooTable table, String what) async {
    final id = a.requireString('id');
    final ChukdooEntity entity = switch (table) {
      ChukdooTable.todos => await _byId(store.todos, id, what),
      ChukdooTable.notes => await _byId(store.notes, id, what),
      ChukdooTable.habits => await _byId(store.habits, id, what),
      ChukdooTable.calendarEvents => await _byId(store.events, id, what),
      _ => throw ChukdooToolError('Cannot delete $what.'),
    };
    await store.delete(table, entity.id);
    return {
      'deleted': entity.id,
      'note': 'Deleted on the server. A device that already has this $what stores it '
          'locally until its data is reset (the app does not sync deletions yet).',
    };
  }

  // ── Handlers: projects ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listProjects(ToolArgs a) async {
    final projects = await store.projects()
      ..sort((x, y) => x.sortOrder.compareTo(y.sortOrder));
    final todos = await store.todos();
    return {
      'projects': [
        for (final p in projects)
          {
            'id': p.id,
            'name': p.name,
            if (p.description != null && p.description!.isNotEmpty) 'description': p.description,
            'color': colorToRgbHex(p.color),
            'open_tasks': todos.where((t) => t.projectId == p.id && !t.isCompleted).length,
          },
      ],
      'tasks_without_project': todos.where((t) => t.projectId == null && !t.isCompleted).length,
    };
  }

  Future<Map<String, dynamic>> _createProject(ToolArgs a) async {
    final name = a.requireString('name');
    final existing = await store.projects();
    if (existing.any((p) => p.name.toLowerCase() == name.toLowerCase())) {
      throw ChukdooToolError('A project named "$name" already exists.');
    }
    final now = store.now();
    final project = Project(
      id: store.newId(),
      userId: store.userId,
      name: name,
      description: a.string('description'),
      color: colorFromInput(a.string('color')) ?? 0xFF808080,
      sortOrder: existing.length,
      createdAt: now,
      updatedAt: now,
    );
    await store.save(ChukdooTable.projects, project);
    return {'created': {'id': project.id, 'name': project.name}};
  }

  // ── Handlers: calendar ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listCalendars(ToolArgs a) async {
    final calendars = await store.calendars()
      ..sort((x, y) => x.sortOrder.compareTo(y.sortOrder));
    return {
      'calendars': [
        for (final c in calendars)
          {
            'id': c.id,
            'name': c.name,
            'color': colorToRgbHex(c.color),
            if (c.isDefault) 'default': true,
            if (!c.isVisible) 'hidden': true,
            if (c.kind != 'general') 'kind': c.kind,
          },
      ],
    };
  }

  /// Events of hidden calendars stay out of listings, like in the app.
  List<CalendarEvent> _visibleEvents(List<CalendarEvent> events, Map<String, Calendar> calendars) =>
      events.where((e) {
        final c = e.calendarId == null ? null : calendars[e.calendarId];
        return c == null || c.isVisible;
      }).toList();

  Future<Map<String, dynamic>> _listEvents(ToolArgs a) async {
    final today = dateOnly(store.now());
    final from = a.dateTime('from') ?? today;
    var to = a.dateTime('to') ?? DateTime(from.year, from.month, from.day + 7);
    // A bare end date means "through that day".
    final toRaw = a.string('to');
    if (toRaw != null && !toRaw.contains('T') && !toRaw.contains(' ') && to == dateOnly(to)) {
      to = DateTime(to.year, to.month, to.day + 1);
    }
    if (!to.isAfter(from)) throw const ChukdooToolError('"to" must be after "from".');
    if (to.difference(from).inDays > 366) {
      throw const ChukdooToolError('Range too long (max 366 days).');
    }
    final calendarsList = await store.calendars();
    final calendars = {for (final c in calendarsList) c.id: c};
    var events = await store.events();
    final calInput = a.string('calendar');
    if (calInput != null) {
      final cal = await _resolveCalendar(calInput);
      events = events.where((e) => e.calendarId == cal.id).toList();
    } else {
      events = _visibleEvents(events, calendars);
    }
    var occ = expandEvents(events, from, to);
    final search = a.string('search')?.toLowerCase();
    if (search != null) {
      occ = occ
          .where((o) =>
              o.event.title.toLowerCase().contains(search) ||
              (o.event.description?.toLowerCase().contains(search) ?? false) ||
              (o.event.location?.toLowerCase().contains(search) ?? false))
          .toList();
    }
    return {
      'from': fmtDateTime(from),
      'to': fmtDateTime(to),
      'count': occ.length,
      'events': [for (final o in occ.take(500)) _eventOut(o, calendars)],
      ..._skippedNote(),
    };
  }

  /// Applies start/end/all_day from args; returns (start, end).
  (DateTime, DateTime) _resolveTimes(ToolArgs a,
      {required DateTime? currentStart, required DateTime? currentEnd, required bool allDay}) {
    var start = a.dateTime('start') ?? currentStart;
    if (start == null) throw const ChukdooToolError('Missing "start".');
    DateTime end;
    if (allDay) {
      start = dateOnly(start);
      final endInput = a.dateTime('end');
      final endDay = endInput != null
          ? dateOnly(endInput)
          : (currentEnd != null && !a.has('start')
              ? dateOnly(currentEnd)
              : (currentStart != null && currentEnd != null
                  ? dateOnly(start.add(dateOnly(currentEnd).difference(dateOnly(currentStart))))
                  : start));
      // The app stores all-day events as 00:00 .. 23:59:59 of the last day.
      end = DateTime(endDay.year, endDay.month, endDay.day, 23, 59, 59);
    } else {
      final endInput = a.dateTime('end');
      final minutes = a.integer('duration_minutes');
      if (endInput != null) {
        end = endInput;
      } else if (minutes != null) {
        end = start.add(Duration(minutes: minutes));
      } else if (currentStart != null && currentEnd != null) {
        end = start.add(currentEnd.difference(currentStart));
      } else {
        end = start.add(const Duration(hours: 1));
      }
    }
    if (!end.isAfter(start)) throw const ChukdooToolError('The end must be after the start.');
    return (start, end);
  }

  Future<Map<String, dynamic>> _createEvent(ToolArgs a) async {
    final now = store.now();
    final allDay = a.boolean('all_day') ?? false;
    final (start, end) = _resolveTimes(a, currentStart: null, currentEnd: null, allDay: allDay);
    final calInput = a.string('calendar');
    final calendar = calInput != null ? await _resolveCalendar(calInput) : await _defaultCalendar();
    final rule = a.string('recurrence_rule');
    _checkRule(rule);
    final event = CalendarEvent(
      id: store.newId(),
      userId: store.userId,
      calendarId: calendar?.id,
      title: a.requireString('title'),
      description: a.text('description'),
      location: a.string('location'),
      startTime: start,
      endTime: end,
      isAllDay: allDay,
      color: colorFromInput(a.string('color')) ?? 0,
      recurrenceRule: rule,
      reminderMinutes: a.intList('reminder_minutes'),
      createdAt: now,
      updatedAt: now,
    );
    await store.save(ChukdooTable.calendarEvents, event);
    final calendars = {for (final c in await store.calendars()) c.id: c};
    return {'created': _eventOut(EventOccurrence(event, start, end), calendars)};
  }

  Future<Map<String, dynamic>> _updateEvent(ToolArgs a) async {
    final event = await _byId(store.events, a.requireString('id'), 'event');
    final now = store.now();
    final occurrence = a.dateTime('occurrence_start');
    final calendars = {for (final c in await store.calendars()) c.id: c};

    if (occurrence != null && event.isRecurring && !event.isException) {
      // Edit one occurrence: an exception event, like editSingleOccurrence.
      final allDay = event.isAllDay;
      final occStart = allDay
          ? DateTime(occurrence.year, occurrence.month, occurrence.day,
              event.startTime.hour, event.startTime.minute, event.startTime.second)
          : occurrence;
      final occEnd = occStart.add(event.duration);
      final (start, end) =
          _resolveTimes(a, currentStart: occStart, currentEnd: occEnd, allDay: a.boolean('all_day') ?? allDay);
      final exception = CalendarEvent(
        id: store.newId(),
        userId: store.userId,
        calendarId: event.calendarId,
        title: a.string('title') ?? event.title,
        description: a.has('description') ? a.text('description') : event.description,
        location: a.has('location') ? a.string('location') : event.location,
        startTime: start,
        endTime: end,
        isAllDay: a.boolean('all_day') ?? allDay,
        color: a.has('color') ? (colorFromInput(a.string('color')) ?? 0) : event.color,
        recurrenceId: event.id,
        originalStartTime: localIso(occStart),
        reminderMinutes: a.intList('reminder_minutes') ?? List.of(event.reminderMinutes),
        createdAt: now,
        updatedAt: now,
      );
      await store.save(ChukdooTable.calendarEvents, exception);
      return {'updated_occurrence': _eventOut(EventOccurrence(exception, start, end), calendars)};
    }

    final allDay = a.boolean('all_day') ?? event.isAllDay;
    if (a.has('start') || a.has('end') || a.has('duration_minutes') || a.has('all_day')) {
      final (start, end) =
          _resolveTimes(a, currentStart: event.startTime, currentEnd: event.endTime, allDay: allDay);
      event.startTime = start;
      event.endTime = end;
      event.isAllDay = allDay;
    }
    if (a.has('title')) event.title = a.requireString('title');
    if (a.has('description')) event.description = a.text('description');
    if (a.has('location')) event.location = a.string('location');
    if (a.has('calendar')) {
      final input = a.string('calendar');
      event.calendarId = input == null ? null : (await _resolveCalendar(input)).id;
    }
    if (a.has('recurrence_rule')) {
      final rule = a.string('recurrence_rule');
      _checkRule(rule);
      event.recurrenceRule = rule;
    }
    if (a.has('reminder_minutes')) event.reminderMinutes = a.intList('reminder_minutes') ?? [];
    if (a.has('color')) event.color = colorFromInput(a.string('color')) ?? 0;
    event.touch(now);
    await store.save(ChukdooTable.calendarEvents, event);
    return {'updated': _eventOut(EventOccurrence(event, event.startTime, event.endTime), calendars)};
  }

  Future<Map<String, dynamic>> _deleteEvent(ToolArgs a) async {
    final event = await _byId(store.events, a.requireString('id'), 'event');
    final occurrence = a.dateTime('occurrence_start');
    if (occurrence != null && event.isRecurring && !event.isException) {
      final now = store.now();
      final occStart = event.isAllDay
          ? DateTime(occurrence.year, occurrence.month, occurrence.day,
              event.startTime.hour, event.startTime.minute, event.startTime.second)
          : occurrence;
      // The app's marker for a deleted occurrence (deleteSingleOccurrence).
      final marker = CalendarEvent(
        id: store.newId(),
        userId: store.userId,
        calendarId: event.calendarId,
        title: '__DELETED__',
        startTime: occStart,
        endTime: occStart.add(event.duration),
        isAllDay: event.isAllDay,
        color: event.color,
        recurrenceId: event.id,
        originalStartTime: localIso(occStart),
        createdAt: now,
        updatedAt: now,
      );
      await store.save(ChukdooTable.calendarEvents, marker);
      return {'deleted_occurrence': fmtDateTime(occStart), 'series': event.id};
    }
    // Deleting a series also removes its exceptions (FK cascade on the server).
    await store.delete(ChukdooTable.calendarEvents, event.id);
    return {
      'deleted': event.id,
      'note': 'Deleted on the server. A device that already has this event stores it '
          'locally until its data is reset (the app does not sync deletions yet).',
    };
  }

  void _checkRule(String? rule) {
    if (rule == null) return;
    if (RRuleHelper.parseRRule(rule) == null) {
      throw ChukdooToolError('Unsupported recurrence_rule "$rule". Use FREQ=DAILY|WEEKLY|MONTHLY|YEARLY '
          'with optional INTERVAL, BYDAY, BYMONTHDAY, COUNT, UNTIL.');
    }
  }

  // ── Handlers: notes ───────────────────────────────────────────────────────

  Future<Map<String, NoteFolder>> _foldersById() async =>
      {for (final f in await store.noteFolders()) f.id: f};

  List<Note> _sortNotes(List<Note> notes) => notes
    ..sort((x, y) {
      if (x.isPinned != y.isPinned) return x.isPinned ? -1 : 1;
      return y.updatedAt.compareTo(x.updatedAt);
    });

  Future<Map<String, dynamic>> _listNotes(ToolArgs a) async {
    final folders = await _foldersById();
    var notes = (await store.notes()).where((n) => n.title.isNotEmpty || n.content.isNotEmpty).toList();
    final folderInput = a.string('folder');
    if (folderInput != null) {
      final folder = await _resolveFolder(folderInput);
      notes = notes.where((n) => n.folderId == folder?.id).toList();
    }
    final limit = a.integer('limit') ?? 50;
    _sortNotes(notes);
    return {
      'count': notes.length,
      'notes': [for (final n in notes.take(limit)) _noteOut(n, folders)],
      ..._skippedNote(),
    };
  }

  Future<Map<String, dynamic>> _searchNotes(ToolArgs a) async {
    final q = a.requireString('query').toLowerCase();
    final folders = await _foldersById();
    final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final hits = (await store.notes()).where((n) {
      final hay = '${n.title}\n${n.content}'.toLowerCase();
      return terms.every(hay.contains);
    }).toList();
    _sortNotes(hits);
    final limit = a.integer('limit') ?? 20;
    return {
      'query': q,
      'count': hits.length,
      'notes': [
        for (final n in hits.take(limit))
          {..._noteOut(n, folders), 'match': _snippet(n.content, terms.first)},
      ],
    };
  }

  String _snippet(String content, String term) {
    final i = content.toLowerCase().indexOf(term);
    if (i < 0) return content.length > 120 ? '${content.substring(0, 120)}...' : content;
    final s = (i - 60).clamp(0, content.length);
    final e = (i + term.length + 60).clamp(0, content.length);
    return '${s > 0 ? '...' : ''}${content.substring(s, e)}${e < content.length ? '...' : ''}';
  }

  Future<Map<String, dynamic>> _getNote(ToolArgs a) async {
    final note = await _byId(store.notes, a.requireString('id'), 'note');
    return {'note': _noteOut(note, await _foldersById(), full: true)};
  }

  Future<Map<String, dynamic>> _createNote(ToolArgs a) async {
    final title = a.string('title') ?? '';
    final content = a.text('content') ?? '';
    if (title.isEmpty && content.trim().isEmpty) {
      throw const ChukdooToolError('A note needs a title or content.');
    }
    final now = store.now();
    final folder = await _resolveFolder(a.string('folder'));
    final note = Note(
      id: store.newId(),
      userId: store.userId,
      title: title,
      content: content,
      folderId: folder?.id,
      isPinned: a.boolean('pinned') ?? false,
      createdAt: now,
      updatedAt: now,
    );
    await store.save(ChukdooTable.notes, note);
    return {'created': _noteOut(note, await _foldersById())};
  }

  Future<Map<String, dynamic>> _updateNote(ToolArgs a) async {
    final note = await _byId(store.notes, a.requireString('id'), 'note');
    if (a.has('title')) note.title = a.string('title') ?? '';
    if (a.has('content')) note.content = a.text('content') ?? '';
    final append = a.text('append');
    if (append != null && append.isNotEmpty) {
      note.content = note.content.isEmpty
          ? append
          : '${note.content}${note.content.endsWith('\n') ? '' : '\n'}$append';
    }
    if (a.has('folder')) note.folderId = (await _resolveFolder(a.string('folder')))?.id;
    if (a.has('pinned')) note.isPinned = a.boolean('pinned') ?? false;
    note.touch(store.now());
    await store.save(ChukdooTable.notes, note);
    return {'updated': _noteOut(note, await _foldersById())};
  }

  Future<Map<String, dynamic>> _listNoteFolders(ToolArgs a) async {
    final folders = await store.noteFolders()
      ..sort((x, y) => x.sortOrder.compareTo(y.sortOrder));
    final notes = await store.notes();
    return {
      'folders': [
        for (final f in folders)
          {'id': f.id, 'name': f.name, 'notes': notes.where((n) => n.folderId == f.id).length},
      ],
      'notes_without_folder': notes.where((n) => n.folderId == null).length,
    };
  }

  // ── Handlers: habits ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listHabits(ToolArgs a) async {
    final day = a.date('date') ?? dateOnly(store.now());
    final habits = await store.habits()
      ..sort((x, y) => x.sortOrder.compareTo(y.sortOrder));
    return {
      'date': dateKey(day),
      'habits': [for (final h in habits) _habitOut(h, day)],
    };
  }

  Future<Map<String, dynamic>> _createHabit(ToolArgs a) async {
    final now = store.now();
    final frequency = a.string('frequency') ?? 'daily';
    if (frequency != 'daily' && frequency != 'weekly') {
      throw const ChukdooToolError('frequency must be daily or weekly.');
    }
    final existing = await store.habits();
    final habit = Habit(
      id: store.newId(),
      userId: store.userId,
      name: a.requireString('name'),
      description: a.string('description'),
      color: colorFromInput(a.string('color')) ?? 0xFF00BFA5,
      frequency: frequency,
      sortOrder: existing.length,
      createdAt: now,
      updatedAt: now,
    );
    await store.save(ChukdooTable.habits, habit);
    return {'created': _habitOut(habit, dateOnly(now))};
  }

  Future<Map<String, dynamic>> _setHabit(ToolArgs a, bool done) async {
    final habit = await _byId(store.habits, a.requireString('id'), 'habit');
    final day = a.date('date') ?? dateOnly(store.now());
    final key = dateKey(day);
    final has = habit.completions.contains(key);
    if (done != has) {
      if (done) {
        habit.completions = [...habit.completions, key]..sort();
      } else {
        habit.completions = habit.completions.where((c) => c != key).toList();
      }
      habit.streak = habit.calculateStreak(store.now());
      habit.touch(store.now());
      await store.save(ChukdooTable.habits, habit);
    }
    return {done ? 'checked' : 'unchecked': _habitOut(habit, day)};
  }

  // ── Misc ──────────────────────────────────────────────────────────────────

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static int _todoOrder(Todo x, Todo y) {
    final dx = x.dueDate, dy = y.dueDate;
    if (dx != null && dy != null) {
      final c = dateOnly(dx).compareTo(dateOnly(dy));
      if (c != 0) return c;
      final tx = x.dueTime?.minutesOfDay ?? 24 * 60, ty = y.dueTime?.minutesOfDay ?? 24 * 60;
      if (tx != ty) return tx.compareTo(ty);
    } else if (dx != null) {
      return -1;
    } else if (dy != null) {
      return 1;
    }
    if (x.priority != y.priority) return x.priority.compareTo(y.priority);
    return y.createdAt.compareTo(x.createdAt);
  }

  Map<String, dynamic> _skippedNote() => store.skipped.isEmpty
      ? const {}
      : {'warning': '${store.skipped.length} row(s) could not be decrypted and were skipped.'};
}
