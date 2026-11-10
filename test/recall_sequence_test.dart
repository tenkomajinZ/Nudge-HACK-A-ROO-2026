import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/models.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();
  final quiz = RecallQuiz.fromJson(
    jsonDecode(File('assets/recall/sample_quiz.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  Future<SessionController> open(
    FakeRepository repository, {
    int index = 0,
  }) async {
    final run = RecallRun(
      id: 'exam',
      tasks: const [],
      stage: 'answering',
      quiz: quiz,
      currentQuestionIndex: index,
    );
    repository.workspace = WorkspaceState(
      recall: RecallState(currentId: run.id, runs: [run]),
    );
    final controller = SessionController(repository: repository);
    await controller.initialize();
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'checking locks original answers and requires manual continuation',
    () async {
      final c = await open(FakeRepository());
      await c.nextRecallQuestion('stale-question');
      await c.checkRecallAnswer('q0');
      expect(c.recallRun!.currentQuestionIndex, 0);
      expect(c.recallRun!.answerChecked, isFalse);
      await c.setRecallAnswer('q1/a', 'a');
      await c.setRecallAnswer('q0/unknown', 'answer');
      expect(c.recallRun!.answers, isEmpty);
      await c.setRecallAnswer('q0/a', '  RETRIEVAL  ');
      await c.checkRecallAnswer('q1');
      expect(c.recallRun!.answerChecked, isFalse);
      await c.checkRecallAnswer('q0');
      await c.setRecallAnswer('q0/a', 'wrong');
      expect(c.recallRun!.answers['q0/a'], '  RETRIEVAL  ');
      expect(c.recallRun!.answerChecked, isTrue);
      expect(c.recallRun!.currentQuestionIndex, 0);
      await Future.wait([
        c.nextRecallQuestion('q0'),
        c.nextRecallQuestion('q0'),
      ]);
      expect(c.recallRun!.currentQuestionIndex, 1);
      expect(c.recallRun!.answerChecked, isFalse);
      await c.setRecallAnswer('q1/a', 'invalid');
      expect(c.recallRun!.answers.containsKey('q1/a'), isFalse);
      await c.setRecallAnswer('q1/a', 'b');
      await c.checkRecallAnswer('q1');
      await c.setRecallAnswer('q1/a', 'a');
      expect(c.recallRun!.answers['q1/a'], 'b');
      expect(c.recallRun!.currentQuestionIndex, 1);
    },
  );

  test('checking waits for pending answer persistence', () async {
    final repository = _DelayedRepository();
    final c = await open(repository);
    repository.saveGate = Completer<void>();
    final answer = c.setRecallAnswer('q0/a', 'retrieval');
    final check = c.checkRecallAnswer('q0');
    expect(c.recallRun!.answerChecked, isFalse);
    repository.saveGate!.complete();
    await Future.wait([answer, check]);
    expect(c.recallRun!.answerChecked, isTrue);
    expect(c.recallRun!.answers['q0/a'], 'retrieval');
  });

  test(
    'multipart requires all answers and retains partial credit at results',
    () async {
      final c = await open(FakeRepository(), index: 9);
      await c.setRecallAnswer('q9/a', 'false');
      await c.checkRecallAnswer('q9');
      expect(c.recallRun!.answerChecked, isFalse);
      await c.setRecallAnswer('q9/b', 'b');
      await c.checkRecallAnswer('q9');
      expect(c.recallRun!.answerChecked, isTrue);
      expect(c.recallRun!.stage, 'answering');
      await c.nextRecallQuestion('q9');
      expect(c.recallRun!.stage, 'answering');
      await c.submitRecall(runId: c.recallRun!.id, allowIncomplete: true);
      expect(c.recallRun!.stage, 'submitted');
      expect(c.recallRun!.quiz!.score(c.recallRun!.answers), 5);
    },
  );

  test(
    'restart and save retry preserve drafts, checked feedback and position',
    () async {
      final repository = FakeRepository();
      final c = await open(repository, index: 1);
      await c.setRecallAnswer('q1/a', 'b');
      var saved = RecallRun.fromJson(
        repository.workspace.recall.current!.toJson(),
      );
      expect(saved.currentQuestionIndex, 1);
      expect(saved.answerChecked, isFalse);
      expect(saved.answers['q1/a'], 'b');
      repository.failSave = true;
      await c.checkRecallAnswer('q1');
      expect(c.error, isNotNull);
      expect(c.recallRun!.answerChecked, isTrue);
      expect(repository.workspace.recall.current!.answerChecked, isFalse);
      await c.nextRecallQuestion('q1');
      expect(c.recallRun!.currentQuestionIndex, 1);
      repository.failSave = false;
      await c.retry();
      saved = RecallRun.fromJson(repository.workspace.recall.current!.toJson());
      final restoredRepo = FakeRepository()
        ..workspace = WorkspaceState(
          recall: RecallState(currentId: saved.id, runs: [saved]),
        );
      final restored = SessionController(repository: restoredRepo);
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.recallRun!.answerChecked, isTrue);
      expect(restored.recallRun!.currentQuestionIndex, 1);
      expect(restored.recallRun!.answers['q1/a'], 'b');
      await restored.nextRecallQuestion('q1');
      expect(restored.recallRun!.currentQuestionIndex, 2);
      expect(restored.recallRun!.answerChecked, isFalse);
      final legacy = saved.toJson()
        ..remove('currentQuestionIndex')
        ..remove('answerChecked')
        ..remove('checkedQuestionIds');
      final old = RecallRun.fromJson(legacy);
      expect(old.currentQuestionIndex, 0);
      expect(old.answerChecked, isFalse);
      expect(old.answers['q1/a'], 'b');
    },
  );

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text(label)),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> show(WidgetTester tester, SessionController controller) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
  }

  testWidgets('typed success shows checkmark and waits for Next question', (
    tester,
  ) async {
    final c = await open(FakeRepository());
    await show(tester, c);
    expect(find.text('Question 1 of 10'), findsOneWidget);
    expect(find.text('2. Choose a review schedule.'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Check answer'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextFormField), 'retrieval');
    await tester.pumpAndSettle();
    await tap(tester, 'Check answer');
    expect(find.text('Good job!'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsWidgets);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
      isFalse,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(c.recallRun!.currentQuestionIndex, 0);
    await tap(tester, 'Next question');
    expect(find.text('Question 2 of 10'), findsOneWidget);
    expect(find.text('Good job!'), findsNothing);
    expect(find.text('Choose the right answer:'), findsOneWidget);
    expect(
      find.text('a. Review across separate study periods'),
      findsOneWidget,
    );
    expect(find.text('b. Do every review in one sitting'), findsOneWidget);
    expect(find.text('c. Never return to the topic'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wrong choice keeps selection, marks correction and explains', (
    tester,
  ) async {
    final c = await open(FakeRepository(), index: 1);
    await show(tester, c);
    await tap(tester, 'b. Do every review in one sitting');
    await tap(tester, 'Check answer');
    expect(find.text('Incorrect'), findsOneWidget);
    expect(find.text('Correct answer'), findsOneWidget);
    expect(find.byIcon(Icons.cancel), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(
      find.text(
        'Separate sessions provide spaced opportunities to retrieve the material.',
      ),
      findsOneWidget,
    );
    expect(c.recallRun!.answers['q1/a'], 'b');
    final wrong = tester.widget<RadioListTile<String>>(
      find.widgetWithText(
        RadioListTile<String>,
        'b. Do every review in one sitting',
      ),
    );
    expect(wrong.enabled, isFalse);
    final correctOption = find.text('a. Review across separate study periods');
    final correctTile = tester.widget<RadioListTile<String>>(
      find.widgetWithText(
        RadioListTile<String>,
        'a. Review across separate study periods',
      ),
    );
    final label = tester.widget<Text>(correctOption);
    final background = correctTile.tileColor!;
    final foreground =
        label.style?.color ??
        DefaultTextStyle.of(tester.element(correctOption)).style.color!;
    final textLuminance = Color.alphaBlend(
      foreground,
      background,
    ).computeLuminance();
    final backgroundLuminance = background.computeLuminance();
    final contrast = textLuminance > backgroundLuminance
        ? (textLuminance + 0.05) / (backgroundLuminance + 0.05)
        : (backgroundLuminance + 0.05) / (textLuminance + 0.05);
    expect(
      contrast,
      greaterThanOrEqualTo(4.5),
      reason: 'Checked answers must stay readable while inputs are locked.',
    );
    await tap(tester, 'Next question');
    expect(find.text('Question 3 of 10'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'wrong fill-in reveals solution and final multipart opens results',
    (tester) async {
      final c = await open(FakeRepository(), index: 9);
      await show(tester, c);
      await tester.enterText(find.byType(TextFormField), 'true');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Check answer'),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, 'a. A sample of understanding');
      await tap(tester, 'Check answer');
      expect(find.text('Correct answer: false'), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(
        find.text(
          'A perfect result describes this attempt. Other concepts and later recall may still need practice.',
        ),
        findsOneWidget,
      );
      await tap(tester, 'Review unanswered');
      expect(c.recallRun!.currentQuestionIndex, 0);
      await c.submitRecall(runId: c.recallRun!.id, allowIncomplete: true);
      await tester.pumpAndSettle();
      expect(find.text('5%'), findsOneWidget);
      expect(find.text('Your recall results'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('choice success remains usable on a phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = await open(FakeRepository(), index: 1);
    await tester.pumpWidget(NudgeApp(controller: c));
    await tester.pumpAndSettle();
    await tap(tester, 'a. Review across separate study periods');
    await tap(tester, 'Check answer');
    expect(find.text('Good job!'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.cancel), findsNothing);
    await tap(tester, 'Next question');
    expect(c.recallRun!.currentQuestionIndex, 2);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.pixels, 0);
    await tester.scrollUntilVisible(
      find.text('Question 3 of 10'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Question 3 of 10'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
