import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/sqlite_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nudge-sqlite-test-');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'version three persists recall attempts and log associations atomically',
    () async {
      var repository = SqliteRepository(databaseName: 'recall.db');
      final subject = await repository.addSubject('Recall', Priority.medium);
      final run = RecallRun(
        id: 'run',
        tasks: [
          const FocusTask(
            id: 'task',
            subjectId: 1,
            title: 'Notes',
            material: RecallMaterial(
              path: '/notes.pdf',
              name: 'notes.pdf',
              live: true,
              consent: true,
            ),
          ).toJson(),
        ],
        stage: 'answering',
        answers: const {'q0/a': 'retrieval'},
        currentQuestionIndex: 1,
        checkedQuestionIds: const {'q0', 'q1'},
      );
      final start = DateTime.utc(2026);
      final log = StudyBlock(
        id: 'block',
        subjectId: subject.id,
        startedAt: start,
        endedAt: start.add(const Duration(seconds: 10)),
        focusSeconds: 10,
        completed: false,
        runId: 'run',
        taskId: 'task',
      );
      await repository.commit(
        null,
        [log],
        workspace: WorkspaceState(
          recall: RecallState(currentId: run.id, runs: [run]),
        ),
      );
      await repository.close();
      repository = SqliteRepository(databaseName: 'recall.db');
      final saved = await repository.load();
      expect(saved.workspace.recall.current!.answers['q0/a'], 'retrieval');
      expect(saved.workspace.recall.current!.currentQuestionIndex, 1);
      expect(saved.workspace.recall.current!.checkedQuestionIds, {'q0', 'q1'});
      final material = FocusTask.fromJson(
        saved.workspace.recall.current!.tasks.single,
      ).material!;
      expect(material.live, isTrue);
      expect(material.consent, isTrue);
      expect(saved.blocks.single.runId, 'run');
      expect(saved.blocks.single.taskId, 'task');
      await expectLater(
        repository.commit(
          ActiveSession(
            blockId: 'bad',
            subjectId: 9999,
            phase: SessionPhase.focus,
            startedAt: start,
            endsAt: start,
          ),
          [],
          workspace: const WorkspaceState(),
        ),
        throwsA(anything),
      );
      expect((await repository.load()).workspace.recall.current!.id, 'run');
      await repository.close();
    },
  );

  test(
    'version-one migration preserves subjects, logs and exact active timestamps',
    () async {
      final path = '${directory.path}/legacy.db';
      final original = await openDatabase(
        path,
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE subjects (id INTEGER PRIMARY KEY, name TEXT NOT NULL, priority INTEGER NOT NULL)',
          );
          await db.execute(
            '''CREATE TABLE study_blocks (id TEXT PRIMARY KEY,
        subject_id INTEGER NOT NULL REFERENCES subjects(id), started_at INTEGER NOT NULL,
        ended_at INTEGER NOT NULL, focus_seconds INTEGER NOT NULL, completed INTEGER NOT NULL)''',
          );
          await db.execute(
            '''CREATE TABLE active_session (singleton INTEGER PRIMARY KEY,
        block_id TEXT NOT NULL, subject_id INTEGER NOT NULL REFERENCES subjects(id),
        phase INTEGER NOT NULL CHECK(phase IN (0,1)), started_at INTEGER NOT NULL, ends_at INTEGER NOT NULL)''',
          );
          await db.insert('subjects', {
            'id': 1,
            'name': 'Calculus',
            'priority': 2,
          });
          await db.insert('study_blocks', {
            'id': 'old',
            'subject_id': 1,
            'started_at': 1000,
            'ended_at': 61000,
            'focus_seconds': 60,
            'completed': 0,
          });
          await db.insert('active_session', {
            'singleton': 1,
            'block_id': 'active',
            'subject_id': 1,
            'phase': 0,
            'started_at': 200000,
            'ends_at': 800000,
          });
        },
      );
      await original.close();
      final repository = SqliteRepository(databaseName: 'legacy.db');
      final saved = await repository.load();
      expect(saved.subjects.single.name, 'Calculus');
      expect(saved.blocks.single.focusSeconds, 60);
      expect(saved.active!.startedAt.millisecondsSinceEpoch, 200000);
      expect(saved.active!.endsAt.millisecondsSinceEpoch, 800000);
      expect(saved.active!.focusDuration, const Duration(minutes: 10));
      expect(saved.active!.planned, false);
      expect(saved.workspace.queue, isEmpty);
      // The rebuilt phase constraint accepts persisted preparation.
      await repository.commit(
        ActiveSession(
          blockId: 'new',
          subjectId: 1,
          phase: SessionPhase.preparing,
          startedAt: DateTime.utc(2026),
          endsAt: DateTime.utc(2026).add(const Duration(seconds: 30)),
          tasks: const [
            FocusTask(id: 'one', subjectId: 1, title: 'Integration'),
          ],
        ),
        [],
        workspace: const WorkspaceState(
          settings: AppSettings(appearance: Appearance.dark),
        ),
      );
      final migrated = await repository.load();
      expect(migrated.active!.phase, SessionPhase.preparing);
      expect(migrated.active!.task!.title, 'Integration');
      expect(migrated.workspace.settings.appearance, Appearance.dark);
      expect(migrated.blocks.length, 1);
      await repository.close();
    },
  );

  test(
    'workspace, log and active state roll back together; duplicate retry is safe',
    () async {
      final repository = SqliteRepository(databaseName: 'atomic.db');
      final subject = await repository.addSubject('Math', Priority.medium);
      final start = DateTime.utc(2026);
      final block = StudyBlock(
        id: 'one',
        subjectId: subject.id,
        startedAt: start,
        endedAt: start.add(const Duration(minutes: 2)),
        focusSeconds: 120,
        completed: true,
      );
      final active = ActiveSession(
        blockId: 'focus',
        subjectId: subject.id,
        phase: SessionPhase.focus,
        startedAt: start,
        endsAt: start.add(const Duration(minutes: 3)),
      );
      await repository.commit(
        active,
        [block],
        workspace: const WorkspaceState(
          settings: AppSettings(appearance: Appearance.dark),
        ),
      );
      await repository.commit(active, [block]);
      expect((await repository.load()).blocks.length, 1);
      final invalid = ActiveSession(
        blockId: 'invalid',
        subjectId: 9999,
        phase: SessionPhase.focus,
        startedAt: start,
        endsAt: start,
      );
      await expectLater(
        repository.commit(invalid, [
          StudyBlock(
            id: 'rollback',
            subjectId: subject.id,
            startedAt: start,
            endedAt: start,
            focusSeconds: 1,
            completed: false,
          ),
        ], workspace: const WorkspaceState()),
        throwsA(anything),
      );
      final after = await repository.load();
      expect(after.blocks.length, 1);
      expect(after.active!.blockId, 'focus');
      expect(after.workspace.settings.appearance, Appearance.dark);
      await repository.close();
    },
  );
}
