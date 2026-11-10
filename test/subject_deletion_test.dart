import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/session_controller.dart';
import 'package:nudge/sqlite_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_repository.dart';

void main() {
  testWidgets(
    'deletion failure is retryable on a narrow dark screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository();
      final controller = SessionController(repository: repository);
      await controller.initialize();
      await controller.addSubject('Math', Priority.medium);
      await controller.updateSettings(
        controller.settings.copyWith(appearance: Appearance.dark),
      );
      await tester.pumpWidget(NudgeApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byTooltip('Task options for Math'),
        120,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byTooltip('Task options for Math')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Task options for Math'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete task'));
      await tester.pumpAndSettle();
      repository.failSave = true;
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(controller.subjects, hasLength(1));
      expect(find.textContaining('Could not delete the task'), findsOneWidget);
      repository.failSave = false;
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(controller.subjects, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('subject deletion can be canceled and keeps history on confirm', (
    tester,
  ) async {
    final repository = FakeRepository();
    final controller = SessionController(repository: repository);
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.medium);
    await controller.saveTask(
      const FocusTask(id: 'task', subjectId: 1, title: 'Limits'),
    );
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.byTooltip('Task options for Calculus')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Task options for Calculus'));
    await tester.pumpAndSettle();
    expect(find.text('Delete task'), findsOneWidget);
    await tester.tap(find.text('Delete task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.subjects, hasLength(1));
    await Scrollable.ensureVisible(
      tester.element(find.byTooltip('Task options for Calculus')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Task options for Calculus'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(controller.subjects, isEmpty);
    expect(controller.queue, isEmpty);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Deleted task'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test(
    'failed deletion keeps tasks and subject; retry deletes only matching identity',
    () async {
      final repository = FakeRepository();
      final controller = SessionController(repository: repository);
      await controller.initialize();
      await controller.addSubject('Same', Priority.medium);
      await controller.addSubject('Same', Priority.medium);
      await controller.saveTask(
        const FocusTask(id: 'a', subjectId: 1, title: 'A'),
      );
      await controller.saveTask(
        const FocusTask(id: 'b', subjectId: 2, title: 'B'),
      );
      repository.failSave = true;
      await expectLater(controller.deleteSubject(1), throwsStateError);
      expect(controller.subjects, hasLength(2));
      expect(controller.queue, hasLength(2));
      repository.failSave = false;
      await controller.deleteSubject(1);
      expect(controller.subjects.single.id, 2);
      expect(controller.queue.single.id, 'b');
      expect(controller.subject(1).isDeleted, isTrue);
      await expectLater(controller.startFocus(1), throwsStateError);
      await expectLater(
        controller.saveTask(
          const FocusTask(id: 'bad', subjectId: 1, title: 'Bad'),
        ),
        throwsStateError,
      );
      controller.dispose();
    },
  );

  test('deletion is blocked during focus and recall', () async {
    final repository = FakeRepository();
    final controller = SessionController(repository: repository);
    await controller.initialize();
    await controller.addSubject('Math', Priority.medium);
    await controller.startFocus(1);
    await expectLater(controller.deleteSubject(1), throwsStateError);
    expect(controller.subjects, hasLength(1));
    controller.dispose();
    repository.active = null;
    repository.workspace = const WorkspaceState(
      recall: RecallState(
        currentId: 'run',
        runs: [RecallRun(id: 'run', tasks: [], stage: 'choice')],
      ),
    );
    final restored = SessionController(repository: repository);
    await restored.initialize();
    await expectLater(restored.deleteSubject(1), throwsStateError);
    restored.dispose();
  });

  test(
    'version 3 migration and deletion retain logs, recall, originals and identity',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('nudge-delete-');
      await databaseFactory.setDatabasesPath(directory.path);
      final path = '${directory.path}/delete.db';
      final old = await openDatabase(
        path,
        version: 3,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE subjects (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, priority INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE study_blocks (id TEXT PRIMARY KEY, subject_id INTEGER NOT NULL REFERENCES subjects(id), started_at INTEGER, ended_at INTEGER, focus_seconds INTEGER, completed INTEGER, run_id TEXT, task_id TEXT)',
          );
          await db.execute(
            'CREATE TABLE active_session (singleton INTEGER PRIMARY KEY, block_id TEXT, subject_id INTEGER REFERENCES subjects(id), phase INTEGER, started_at INTEGER, ends_at INTEGER, details TEXT)',
          );
          await db.execute(
            'CREATE TABLE workspace (singleton INTEGER PRIMARY KEY, details TEXT NOT NULL)',
          );
          await db.insert('subjects', {'id': 1, 'name': 'Math', 'priority': 1});
          await db.insert('study_blocks', {
            'id': 'b',
            'subject_id': 1,
            'started_at': 1,
            'ended_at': 1001,
            'focus_seconds': 1,
            'completed': 1,
          });
        },
      );
      await old.close();
      final original = File('${directory.path}/notes.pdf');
      await original.writeAsString('saved original');
      var repository = SqliteRepository(databaseName: 'delete.db');
      final history = RecallRun(
        id: 'past',
        tasks: [
          FocusTask(
            id: 'past-task',
            subjectId: 1,
            title: 'Past notes',
            material: RecallMaterial(path: original.path, name: 'notes.pdf'),
          ).toJson(),
        ],
        stage: 'abandoned',
      );
      await repository.commit(
        null,
        [],
        workspace: WorkspaceState(recall: RecallState(runs: [history])),
      );
      var controller = SessionController(repository: repository);
      await controller.initialize();
      expect(controller.subject(1).isDeleted, isFalse);
      await controller.saveTask(
        FocusTask(
          id: 'a',
          subjectId: 1,
          title: 'Notes',
          material: RecallMaterial(path: original.path, name: 'notes.pdf'),
        ),
      );
      await controller.deleteSubject(1);
      controller.dispose();
      await repository.close();
      repository = SqliteRepository(databaseName: 'delete.db');
      controller = SessionController(repository: repository);
      await controller.initialize();
      expect(controller.subjects, isEmpty);
      expect(controller.historySubjects.single.name, 'Math');
      expect(controller.totalSeconds(1), 1);
      expect(controller.queue, isEmpty);
      expect(controller.recallHistory.single.id, 'past');
      expect(await original.exists(), isTrue);
      await controller.addSubject('Math', Priority.medium);
      expect(controller.subjects.single.id, isNot(1));
      // A workspace-write error must roll back the soft delete too.
      final db = await openDatabase(path);
      await db.execute(
        "CREATE TRIGGER fail_workspace BEFORE INSERT ON workspace BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
      );
      await expectLater(
        controller.deleteSubject(controller.subjects.single.id),
        throwsA(anything),
      );
      expect(
        (await repository.load()).subjects.where((s) => !s.isDeleted),
        hasLength(1),
      );
      controller.dispose();
      await repository.close();
      await directory.delete(recursive: true);
    },
  );
}
