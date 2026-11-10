import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/hold_to_submit_button.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/session_controller.dart';

import 'fake_repository.dart';

class _DelayedRepository extends FakeRepository {
  Completer<void>? gate;
  @override
  Future<void> commit(
    ActiveSession? active,
    List<StudyBlock> blocks, {
    WorkspaceState? workspace,
  }) async {
    await gate?.future;
    await super.commit(active, blocks, workspace: workspace);
  }
}

void main() {
  final quiz = RecallQuiz.fromJson(
    jsonDecode(File('assets/recall/sample_quiz.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  Future<SessionController> open(WidgetTester tester, {int index = 0}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final run = RecallRun(
      id: 'navigation',
      tasks: const [],
      stage: 'answering',
      quiz: quiz,
      currentQuestionIndex: index,
    );
    final repo = FakeRepository()
      ..workspace = WorkspaceState(
        recall: RecallState(currentId: run.id, runs: [run]),
      );
    final c = SessionController(repository: repo);
    await c.initialize();
    addTearDown(c.dispose);
    await tester.pumpWidget(NudgeApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label);
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        160,
        scrollable: RegExp(r'^Question \d+$').hasMatch(label)
            ? find.byType(Scrollable).last
            : find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<SessionController> controller(FakeRepository repo) async {
    final run = RecallRun(
      id: 'state',
      tasks: const [],
      stage: 'answering',
      quiz: quiz,
    );
    repo.workspace = WorkspaceState(
      recall: RecallState(currentId: run.id, runs: [run]),
    );
    final c = SessionController(repository: repo);
    await c.initialize();
    addTearDown(c.dispose);
    return c;
  }

  test(
    'jumping restores locked feedback and persists it across restart',
    () async {
      final repo = FakeRepository();
      final c = await controller(repo);
      await c.setRecallAnswer('q0/a', 'retrieval');
      await c.checkRecallAnswer('q0');
      await c.goToRecallQuestion('q2', fromQuestionId: 'q0');
      await c.setRecallAnswer('q2/a', 'draft');
      await c.goToRecallQuestion('q0', fromQuestionId: 'q2');
      expect(c.recallRun!.answerChecked, isTrue);
      await c.setRecallAnswer('q0/a', 'replacement');
      expect(c.recallRun!.answers['q0/a'], 'retrieval');
      final restored = SessionController(repository: repo);
      await restored.initialize();
      addTearDown(restored.dispose);
      expect(restored.recallRun!.answerChecked, isTrue);
      await restored.goToRecallQuestion('q2', fromQuestionId: 'q0');
      expect(restored.recallRun!.answerChecked, isFalse);
      expect(restored.recallRun!.answers['q2/a'], 'draft');
      await restored.goToRecallQuestion('q3', fromQuestionId: 'stale');
      expect(restored.recallRun!.currentQuestionIndex, 2);
    },
  );

  test(
    'legacy sequential saves retain earlier checks without locking new skipped drafts',
    () {
      final old =
          RecallRun(
              id: 'old',
              tasks: const [],
              stage: 'answering',
              quiz: quiz,
              currentQuestionIndex: 1,
              answers: const {'q0/a': 'retrieval', 'q1/a': 'b'},
            ).toJson()
            ..remove('checkedQuestionIds')
            ..['answerChecked'] = true;
      final migrated = RecallRun.fromJson(old);
      expect(migrated.checkedQuestionIds, {'q0', 'q1'});
      expect(migrated.copyWith(currentQuestionIndex: 0).answerChecked, isTrue);
      final modern = migrated.copyWith(checkedQuestionIds: {}).toJson();
      expect(RecallRun.fromJson(modern).checkedQuestionIds, isEmpty);
    },
  );

  test(
    'submission queues behind drafts, grades partial credit and retries failed storage',
    () async {
      final repo = _DelayedRepository();
      final c = await controller(repo);
      await c.goToRecallQuestion('q9', fromQuestionId: 'q0');
      repo.gate = Completer<void>();
      final draft = c.setRecallAnswer('q9/a', 'false');
      final submit = c.submitRecall(runId: 'state', allowIncomplete: true);
      expect(c.recallRun!.stage, 'answering');
      repo.failSave = true;
      repo.gate!.complete();
      await Future.wait([draft, submit]);
      expect(c.recallRun!.stage, 'answering');
      expect(c.error, isNotNull);
      repo.failSave = false;
      await c.retry();
      repo.failSave = true;
      await c.submitRecall(runId: 'state', allowIncomplete: true);
      expect(c.recallRun!.stage, 'submitted');
      expect(c.recallRun!.quiz!.score(c.recallRun!.answers), 5);
      repo.failSave = false;
      await c.retry();
      expect(repo.workspace.recall.current!.stage, 'submitted');
      expect(repo.workspace.recall.current!.answers['q9/a'], 'false');
    },
  );

  test('normal submission rejects incomplete or stale attempts', () async {
    final c = await controller(FakeRepository());
    await c.submitRecall(runId: 'state');
    await c.submitRecall(runId: 'other', allowIncomplete: true);
    expect(c.recallRun!.stage, 'answering');
    for (final q in quiz.questions) {
      await c.goToRecallQuestion(
        q.id,
        fromQuestionId: c.recallRun!.currentQuestion!.id,
      );
      for (final p in q.parts) {
        await c.setRecallAnswer(
          '${q.id}/${p.id}',
          p.kind == 'choice' ? p.correct : p.accepted.first,
        );
      }
    }
    await c.submitRecall(runId: 'state');
    await c.submitRecall(runId: 'state');
    expect(c.recallRun!.stage, 'submitted');
    expect(c.recallRun!.quiz!.score(c.recallRun!.answers), 100);
  });

  testWidgets(
    'cancelled and keyboard holds use the same real two-second threshold',
    (tester) async {
      var submitted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Align(
                alignment: Alignment.topCenter,
                child: HoldToSubmitButton(
                  enabled: true,
                  onHeld: () => submitted++,
                ),
              ),
            ),
          ),
        ),
      );
      final hold = find.text('Hold to submit early');
      var gesture = await tester.startGesture(tester.getCenter(hold));
      await tester.pump(const Duration(seconds: 1));
      await gesture.moveTo(const Offset(2, 400));
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      expect(submitted, 0);
      gesture = await tester.startGesture(tester.getCenter(hold));
      await tester.pump(const Duration(seconds: 1));
      await gesture.cancel();
      await tester.pump(const Duration(seconds: 2));
      expect(submitted, 0);
      await tester.tap(hold);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 1999));
      expect(submitted, 0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(seconds: 1));
      expect(submitted, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(seconds: 2));
      expect(submitted, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(submitted, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'last question reviews unanswered and submits a complete unchecked attempt',
    (tester) async {
      final c = await open(tester, index: 9);
      await tap(tester, 'Review unanswered');
      expect(c.recallRun!.currentQuestionIndex, 0);
      for (final q in quiz.questions) {
        await c.goToRecallQuestion(
          q.id,
          fromQuestionId: c.recallRun!.currentQuestion!.id,
        );
        for (final p in q.parts) {
          await c.setRecallAnswer(
            '${q.id}/${p.id}',
            p.kind == 'choice' ? p.correct : p.accepted.first,
          );
        }
      }
      await tester.pumpAndSettle();
      await tap(tester, 'Submit answers');
      expect(find.text('100%'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('assistive activation waits two seconds and can be cancelled', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldToSubmitButton(enabled: true, onHeld: () => calls++),
        ),
      ),
    );
    final target = find.bySemanticsLabel('Hold to submit early');
    final node = tester.getSemantics(target);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(calls, 0);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 0);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets(
    'focus loss, backgrounding and removing the screen cancel a hold',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HoldToSubmitButton(enabled: true, onHeld: () => calls++),
          ),
        ),
      );
      final target = find.text('Hold to submit early');
      var gesture = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(seconds: 1));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      expect(calls, 0);
      gesture = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await gesture.up();
      expect(calls, 0);
      gesture = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final appearance in [Appearance.light, Appearance.dark]) {
    for (final size in [
      const Size(375, 812),
      const Size(844, 390),
      const Size(1024, 768),
    ]) {
      testWidgets(
        'navigator fits $size with large text in ${appearance.name}',
        (tester) async {
          final c = await open(tester);
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await c.updateSettings(c.settings.copyWith(appearance: appearance));
          await tester.pumpAndSettle();
          if (size.width >= 840) {
            expect(find.text('Question 1'), findsOneWidget);
            await tap(tester, 'Question 3');
            expect(c.recallRun!.currentQuestionIndex, 2);
          } else {
            await tap(tester, 'Questions');
            expect(find.text('Question 1'), findsOneWidget);
            await tester.tap(find.byTooltip('Close question list'));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  test('Next skips an unanswered question without submitting', () async {
    final run = RecallRun(
      id: 'skip',
      tasks: const [],
      stage: 'answering',
      quiz: quiz,
    );
    final repo = FakeRepository()
      ..workspace = WorkspaceState(
        recall: RecallState(currentId: run.id, runs: [run]),
      );
    final c = SessionController(repository: repo);
    await c.initialize();
    addTearDown(c.dispose);
    await c.nextRecallQuestion('q0');
    expect(c.recallRun!.currentQuestionIndex, 1);
    expect(c.recallRun!.stage, 'answering');
  });

  testWidgets('phone question list preserves a draft when jumping back', (
    tester,
  ) async {
    final c = await open(tester);
    await tester.enterText(find.byType(TextFormField), 'retrieval draft');
    await tester.pumpAndSettle();
    await tap(tester, 'Questions');
    await tap(tester, 'Question 3');
    expect(c.recallRun!.currentQuestionIndex, 2);
    await tap(tester, 'Questions');
    await tap(tester, 'Question 1');
    expect(find.text('retrieval draft'), findsOneWidget);
    expect(c.recallRun!.answerChecked, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('early submission requires a full hold and confirmation', (
    tester,
  ) async {
    final c = await open(tester);
    await tester.enterText(find.byType(TextFormField), 'retrieval');
    await tester.pumpAndSettle();
    final hold = find.text('Hold to submit early');
    await tester.scrollUntilVisible(
      hold,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(hold);
    await tester.pumpAndSettle();
    var gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.text('Submit early?'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(c.recallRun!.stage, 'answering');
    gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(milliseconds: 1999));
    expect(find.text('Submit early?'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Submit early?'), findsOneWidget);
    expect(find.textContaining('9 questions'), findsOneWidget);
    await tap(tester, 'Keep answering');
    expect(c.recallRun!.stage, 'answering');
    gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(seconds: 2));
    await gesture.up();
    await tester.pumpAndSettle();
    await tap(tester, 'Submit answers');
    expect(c.recallRun!.stage, 'submitted');
    expect(find.text('10%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
