import 'dart:convert';

import 'package:path/path.dart' as paths;
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'study_repository.dart';

class SqliteRepository implements StudyRepository {
  SqliteRepository({this.databaseName = 'nudge.db'});
  final String databaseName;
  Database? _database;

  static Future<void> _createActive(DatabaseExecutor db) => db.execute('''
    CREATE TABLE active_session (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      block_id TEXT NOT NULL, subject_id INTEGER NOT NULL REFERENCES subjects(id),
      phase INTEGER NOT NULL CHECK(phase IN (0, 1, 2)),
      started_at INTEGER NOT NULL, ends_at INTEGER NOT NULL, details TEXT)
  ''');
  static Future<void> _createWorkspace(DatabaseExecutor db) => db.execute('''
    CREATE TABLE workspace (singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      details TEXT NOT NULL)
  ''');

  Future<Database> _open() async {
    if (_database != null) return _database!;
    final directory = await getDatabasesPath();
    _database = await openDatabase(
      paths.join(directory, databaseName),
      version: 4,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute(
          '''CREATE TABLE subjects (
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
          priority INTEGER NOT NULL CHECK(priority BETWEEN 0 AND 2),
          is_deleted INTEGER NOT NULL DEFAULT 0 CHECK(is_deleted IN (0, 1)))''',
        );
        await db.execute(
          '''CREATE TABLE study_blocks (
          id TEXT PRIMARY KEY, subject_id INTEGER NOT NULL REFERENCES subjects(id),
          started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL,
          focus_seconds INTEGER NOT NULL CHECK(focus_seconds >= 0),
          completed INTEGER NOT NULL CHECK(completed IN (0, 1)), run_id TEXT, task_id TEXT)''',
        );
        await _createActive(db);
        await _createWorkspace(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE active_session RENAME TO active_session_v1',
          );
          await _createActive(db);
          await db.execute('''INSERT INTO active_session
            (singleton, block_id, subject_id, phase, started_at, ends_at)
            SELECT singleton, block_id, subject_id, phase, started_at, ends_at
            FROM active_session_v1''');
          await db.execute('DROP TABLE active_session_v1');
          await _createWorkspace(db);
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE study_blocks ADD COLUMN run_id TEXT');
          await db.execute('ALTER TABLE study_blocks ADD COLUMN task_id TEXT');
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE subjects ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0 CHECK(is_deleted IN (0, 1))',
          );
        }
      },
    );
    return _database!;
  }

  DateTime _date(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);

  @override
  Future<StoredState> load() async {
    final db = await _open();
    return db.transaction((txn) async {
      final subjects = await txn.query(
        'subjects',
        orderBy: 'priority DESC, id',
      );
      final blocks = await txn.query(
        'study_blocks',
        orderBy: 'started_at DESC',
      );
      final sessions = await txn.query('active_session');
      final workspace = await txn.query('workspace');
      final row = sessions.isEmpty ? null : sessions.single;
      return StoredState(
        subjects: subjects
            .map(
              (s) => Subject(
                id: s['id'] as int,
                name: s['name'] as String,
                priority: Priority.values[s['priority'] as int],
                isDeleted: s['is_deleted'] == 1,
              ),
            )
            .toList(),
        blocks: blocks
            .map(
              (b) => StudyBlock(
                id: b['id'] as String,
                subjectId: b['subject_id'] as int,
                startedAt: _date(b['started_at']),
                endedAt: _date(b['ended_at']),
                focusSeconds: b['focus_seconds'] as int,
                completed: b['completed'] == 1,
                runId: b['run_id'] as String?,
                taskId: b['task_id'] as String?,
              ),
            )
            .toList(),
        active: row == null
            ? null
            : row['details'] != null
            ? ActiveSession.fromJson(
                jsonDecode(row['details'] as String) as Map<String, dynamic>,
              )
            : ActiveSession(
                blockId: row['block_id'] as String,
                subjectId: row['subject_id'] as int,
                phase: SessionPhase.values[row['phase'] as int],
                startedAt: _date(row['started_at']),
                endsAt: _date(row['ends_at']),
              ),
        workspace: workspace.isEmpty
            ? const WorkspaceState()
            : WorkspaceState.fromJson(
                jsonDecode(workspace.single['details'] as String)
                    as Map<String, dynamic>,
              ),
      );
    });
  }

  @override
  Future<Subject> addSubject(String name, Priority priority) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError('Enter a task name.');
    final db = await _open();
    final id = await db.insert('subjects', {
      'name': clean,
      'priority': priority.index,
    });
    return Subject(id: id, name: clean, priority: priority);
  }

  @override
  Future<void> updateSubject(Subject subject) async {
    if (subject.name.trim().isEmpty) {
      throw ArgumentError('Enter a task name.');
    }
    final db = await _open();
    final changed = await db.update(
      'subjects',
      {'name': subject.name.trim(), 'priority': subject.priority.index},
      where: 'id = ? AND is_deleted = 0',
      whereArgs: [subject.id],
    );
    if (changed != 1) throw StateError('Task no longer exists.');
  }

  @override
  Future<void> deleteSubject(
    int id, {
    required WorkspaceState workspace,
  }) async {
    final db = await _open();
    await db.transaction((txn) async {
      if ((await txn.query('active_session')).isNotEmpty) {
        throw StateError(
          'Finish your study or recall run before deleting a task.',
        );
      }
      final changed = await txn.update(
        'subjects',
        {'is_deleted': 1},
        where: 'id = ? AND is_deleted = 0',
        whereArgs: [id],
      );
      if (changed != 1) throw StateError('Task no longer exists.');
      await txn.insert('workspace', {
        'singleton': 1,
        'details': jsonEncode(workspace.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> commit(
    ActiveSession? active,
    List<StudyBlock> newBlocks, {
    WorkspaceState? workspace,
  }) async {
    final db = await _open();
    await db.transaction((txn) async {
      for (final block in newBlocks) {
        // Ignore only an existing ID, never foreign-key or validation errors.
        if ((await txn.query(
          'study_blocks',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [block.id],
        )).isEmpty) {
          await txn.insert('study_blocks', {
            'id': block.id,
            'subject_id': block.subjectId,
            'started_at': block.startedAt.millisecondsSinceEpoch,
            'ended_at': block.endedAt.millisecondsSinceEpoch,
            'focus_seconds': block.focusSeconds,
            'completed': block.completed ? 1 : 0,
            'run_id': block.runId,
            'task_id': block.taskId,
          });
        }
      }
      await txn.delete('active_session');
      if (active != null) {
        await txn.insert('active_session', {
          'singleton': 1,
          'block_id': active.blockId,
          'subject_id': active.subjectId,
          'phase': active.phase.index,
          'started_at': active.startedAt.millisecondsSinceEpoch,
          'ends_at': active.endsAt.millisecondsSinceEpoch,
          'details': jsonEncode(active.toJson()),
        });
      }
      if (workspace != null) {
        await txn.insert('workspace', {
          'singleton': 1,
          'details': jsonEncode(workspace.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
