import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/models.dart';
import 'package:nudge/session_controller.dart';
import 'package:nudge/sqlite_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real SQLite persists the cycle and atomically rejects bad writes', (
    tester,
  ) async {
    var time = DateTime.utc(2026, 10, 12, 12);
    final databaseName =
        'nudge-test-${DateTime.now().microsecondsSinceEpoch}.db';
    var repository = SqliteRepository(databaseName: databaseName);
    var controller = SessionController(
      repository: repository,
      clock: () => time,
    );
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Calculus');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final subject = controller.subjects.single;
    await controller.startFocus(subject.id);
    time = time.add(const Duration(minutes: 10));
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Break'), findsOneWidget);
    expect(controller.totalSeconds(subject.id), 600);

    // Reconstruct both the database connection and controller like a cold start.
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await repository.close();
    repository = SqliteRepository(databaseName: databaseName);
    controller = SessionController(repository: repository, clock: () => time);
    time = time.add(const Duration(minutes: 20));
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Break over'), findsOneWidget);
    expect(controller.blocks.length, 1);
    await tester.scrollUntilVisible(find.text('Continue'), 120);
    await Scrollable.ensureVisible(
      tester.element(find.text('Continue')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Focus'), findsOneWidget);
    time = time.add(const Duration(seconds: 90));
    await tester.scrollUntilVisible(find.text('Finish'), 120);
    await Scrollable.ensureVisible(
      tester.element(find.text('Finish')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(controller.totalSeconds(subject.id), 690);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Calculus'), findsOneWidget);
    expect(find.text('11.5 min'), findsOneWidget);

    final saved = await repository.load();
    // Retrying the same blocks does not duplicate them.
    await repository.commit(null, saved.blocks);
    expect((await repository.load()).blocks.length, 2);
    // A foreign-key failure must roll back both the new log and active snapshot.
    await expectLater(
      repository.commit(
        ActiveSession(
          blockId: 'invalid',
          subjectId: 999999,
          phase: SessionPhase.focus,
          startedAt: time,
          endsAt: time.add(const Duration(minutes: 10)),
        ),
        [
          StudyBlock(
            id: 'rollback-probe',
            subjectId: subject.id,
            startedAt: time,
            endedAt: time.add(const Duration(seconds: 1)),
            focusSeconds: 1,
            completed: false,
          ),
        ],
      ),
      throwsA(anything),
    );
    final afterFailure = await repository.load();
    expect(afterFailure.blocks.length, 2);
    expect(afterFailure.active, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await repository.close();
  });
}
