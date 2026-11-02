import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'api/rpc_client.dart';
import 'credentials.dart';
import 'crypto/field_cipher.dart';
import 'models/entities.dart';

/// A row that could not be decrypted or parsed. Reported, never fatal.
class SkippedRow {
  final ChukdooTable table;
  final String id;
  final String reason;
  const SkippedRow(this.table, this.id, this.reason);
}

/// Decrypted, typed access to the account through the device API.
///
/// Reads pull the whole table (the server filters by owner) and decrypt it
/// locally; results are cached for [cacheTtl] and dropped on every write.
/// Writes encrypt locally and upsert payload + clear columns exactly like the
/// app does, so the app's next pull picks them up.
class ChukdooStore {
  final ChukdooCredentials credentials;
  final DeviceApi api;
  final FieldCipher cipher;
  final Duration cacheTtl;
  final DateTime Function() clock;

  static const Uuid _uuid = Uuid();

  final Map<ChukdooTable, _CacheEntry> _cache = {};
  final List<SkippedRow> skipped = [];

  ChukdooStore({
    required this.credentials,
    http.Client? httpClient,
    DeviceApi? api,
    this.cacheTtl = const Duration(seconds: 15),
    DateTime Function()? clock,
  })  : api = api ??
            DeviceApi(
              rpc: SupabaseRpc(
                supabaseUrl: credentials.supabaseUrl,
                anonKey: credentials.anonKey,
                client: httpClient,
              ),
              deviceToken: credentials.deviceToken,
            ),
        cipher = FieldCipher.fromBase64(credentials.dataKey),
        clock = clock ?? DateTime.now;

  String get userId => credentials.userId;
  String newId() => _uuid.v4();
  DateTime now() => clock();

  void invalidate([ChukdooTable? table]) =>
      table == null ? _cache.clear() : _cache.remove(table);

  Future<List<Todo>> todos() => _load(ChukdooTable.todos, Todo.fromRemote);
  Future<List<Project>> projects() =>
      _load(ChukdooTable.projects, Project.fromRemote);
  Future<List<Calendar>> calendars() =>
      _load(ChukdooTable.calendars, Calendar.fromRemote);
  Future<List<CalendarEvent>> events() =>
      _load(ChukdooTable.calendarEvents, CalendarEvent.fromRemote);
  Future<List<Habit>> habits() => _load(ChukdooTable.habits, Habit.fromRemote);
  Future<List<Note>> notes() => _load(ChukdooTable.notes, Note.fromRemote);
  Future<List<NoteFolder>> noteFolders() =>
      _load(ChukdooTable.noteFolders, NoteFolder.fromRemote);

  /// Encrypts and upserts [entity]. Call [ChukdooEntity.touch] first on edits.
  Future<void> save(ChukdooTable table, ChukdooEntity entity) async {
    entity.userId = userId;
    final encrypted = await cipher.encryptJson(entity.remotePayload());
    await api.upsert(table, entity.remoteRow(encrypted));
    _cache.remove(table);
  }

  /// Hard delete on the server (the app deletes the same way).
  Future<bool> delete(ChukdooTable table, String id) async {
    final n = await api.delete(table, id);
    _cache.remove(table);
    return n > 0;
  }

  Future<List<T>> _load<T>(
    ChukdooTable table,
    T Function(Map<String, dynamic> row, Map<String, dynamic> payload) parse,
  ) async {
    final cached = _cache[table];
    if (cached != null && clock().difference(cached.at) < cacheTtl) {
      return cached.items.cast<T>();
    }
    final rows = await api.pull(table);
    final items = <T>[];
    skipped.removeWhere((s) => s.table == table);
    for (final row in rows) {
      final id = row['id']?.toString() ?? '?';
      try {
        final payload =
            await cipher.decryptJson(row['encrypted_payload'] as String);
        items.add(parse(row, payload));
      } catch (e) {
        skipped.add(SkippedRow(table, id, e.toString()));
      }
    }
    _cache[table] = _CacheEntry(clock(), items);
    return items;
  }

  void close() => api.rpc.close();
}

class _CacheEntry {
  final DateTime at;
  final List<Object?> items;
  _CacheEntry(this.at, this.items);
}
