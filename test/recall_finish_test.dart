import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_gateway.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/session_controller.dart';

import 'fake_repository.dart';

class _DelayedRepository extends FakeRepository {
  Completer<void>? saveGate;

  @override
  Future<void> commit(
    ActiveSession? active,
    List<StudyBlock> newBlocks, {
    WorkspaceState? workspace,
  }) async {
    await saveGate?.future;
    await super.commit(active, newBlocks, workspace: workspace);
  }
}

void main() {
  for (final stage in ['choice', 'submitted']) {
    for (final failSave in [false, if (stage == 'submitted') true]) {
      testWidgets(
        'finishing $stage handles a delayed ${failSave ? 'failed' : 'successful'} save',
        (tester) async {
          final fixture = await tester.runAsync(
            () =>
                SampleRecallGateway().submit(RecallMaterial.sample, 'demo', []),
          );
          final run = RecallRun(
            id: 'demo',
            tasks: const [],
            entries: const [],
            stage: stage,
            quiz: fixture!.quiz!,
          );
          final repository = _DelayedRepository()
            ..workspace = WorkspaceState(
              recall: RecallState(currentId: run.id, runs: [run]),
            );
          final controller = SessionController(repository: repository);
          await controller.initialize();
          await tester.pumpWidget(NudgeApp(controller: controller));
          await tester.pumpAndSettle();

          repository.saveGate = Completer<void>();
          repository.failSave = failSave;
          final finish = find.text(switch (stage) {
            'choice' => 'Finish without recall',
            _ => 'Finish for now',
          });
          await tester.scrollUntilVisible(
            finish,
            400,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(finish);
          // Render while the real controller has cleared the run but is still
          // waiting for storage, rather than completing the save in one frame.
          await tester.pump();
          final pendingSaveException = tester.takeException();
          expect(controller.busy, isTrue);
          expect(controller.recallRun, isNull);

          repository.saveGate!.complete();
          await tester.pumpAndSettle();
          final completedSaveException = tester.takeException();
          expect(pendingSaveException, isNull);
          expect(completedSaveException, isNull);
          expect(find.text('One small start.'), findsOneWidget);
          expect(
            controller.recallHistory.single.stage,
            stage == 'submitted' ? 'submitted' : 'finished',
          );
          if (failSave) {
            expect(
              find.textContaining('Changes are only in memory'),
              findsOneWidget,
            );
            repository.failSave = false;
            await controller.retry();
            await tester.pumpAndSettle();
          }
          expect(repository.workspace.recall.currentId, isNull);
          expect(
            repository.workspace.recall.runs.single.stage,
            stage == 'submitted' ? 'submitted' : 'finished',
          );
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        },
      );
    }
  }
}
