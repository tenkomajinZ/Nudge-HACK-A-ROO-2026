import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:nudge/focus_widgets.dart';
import 'package:nudge/main.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_gateway.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/session_controller.dart';
import 'fake_repository.dart';

class _PauseSaveRepository extends FakeRepository {
  final finishPauseSave = Completer<void>();

  @override
  Future<void> commit(
    ActiveSession? active,
    List<StudyBlock> newBlocks, {
    WorkspaceState? workspace,
  }) async {
    if (active?.isPaused == true) await finishPauseSave.future;
    await super.commit(active, newBlocks, workspace: workspace);
  }
}

void main() {
  testWidgets('Pause freezes the visible ring while the save is pending', (
    tester,
  ) async {
    var time = DateTime.utc(2026, 10, 31);
    final repository = _PauseSaveRepository();
    final controller = SessionController(
      repository: repository,
      clock: () => time,
    );
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    await controller.startPlan(
      tasks: const [FocusTask(id: 'a', subjectId: 1, title: 'Integrals')],
    );
    await controller.readyToFocus();
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();

    final ring = find
        .descendant(
          of: find.byType(CountdownRing),
          matching: find.byType(CustomPaint),
        )
        .first;
    time = time.add(const Duration(minutes: 1));
    await controller.refresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    final halfway = paints..arc(sweepAngle: 1.9 * math.pi);
    expect(ring, halfway);

    await tester.tap(find.byTooltip('Pause timer'));
    await tester.pump();
    expect(ring, halfway);
    await tester.pump(const Duration(milliseconds: 500));
    expect(ring, halfway);
    expect(find.byTooltip('Resume timer'), findsOneWidget);
    expect(find.text('9:00'), findsOneWidget);
    expect(repository.active!.isPaused, isFalse);

    repository.finishPauseSave.complete();
    await tester.pumpAndSettle();
    expect(ring, halfway);
    await tester.tap(find.byTooltip('Resume timer'));
    await tester.pumpAndSettle();
    expect(ring, paints..arc(sweepAngle: 1.8 * math.pi));

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'break Home keeps the current task featured and preserves the queue',
    (tester) async {
      var time = DateTime.utc(2026, 10, 31);
      final controller = SessionController(
        repository: FakeRepository(),
        clock: () => time,
      );
      await controller.initialize();
      await controller.addSubject('Calculus', Priority.high);
      await controller.saveTask(
        const FocusTask(id: 'a', subjectId: 1, title: 'First task'),
      );
      await controller.saveTask(
        const FocusTask(id: 'b', subjectId: 1, title: 'Next task'),
      );
      await controller.startPlan();
      await controller.readyToFocus();
      await tester.pumpWidget(NudgeApp(controller: controller));
      await tester.pumpAndSettle();
      time = time.add(const Duration(minutes: 10));
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(controller.active!.phase, SessionPhase.rest);
      await tester.tap(find.byTooltip('Home'));
      await tester.pumpAndSettle();
      expect(find.text('First task'), findsOneWidget);
      expect(find.text('Up next'), findsNothing);
      expect(controller.queue.single.title, 'Next task');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'recall completion outside the timer stays on History and resumes recall',
    (tester) async {
      await tester.runAsync(
        () => rootBundle.loadString('assets/recall/sample_quiz.json'),
      );
      var time = DateTime.utc(2026, 10, 31);
      final controller = SessionController(
        repository: FakeRepository(),
        clock: () => time,
        recallGateway: SampleRecallGateway(),
      );
      await controller.initialize();
      await controller.addSubject('Calculus', Priority.high);
      await controller.startPlan(
        tasks: const [
          FocusTask(
            id: 'recall',
            subjectId: 1,
            title: 'Review',
            material: RecallMaterial.sample,
            config: TimerConfig(focusMinutes: 1),
          ),
        ],
      );
      await controller.readyToFocus();
      await tester.pumpWidget(NudgeApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      time = time.add(const Duration(minutes: 1));
      await tester.runAsync(controller.refresh);
      await tester.pumpAndSettle();
      expect(controller.recallRun!.stage, 'choice');
      expect(find.text('Study time'), findsOneWidget);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue recall'));
      await tester.pumpAndSettle();
      expect(find.text('Ready to recall?'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'Home leaves and returns to a running session without restarting',
    (tester) async {
      var time = DateTime.utc(2026, 10, 31);
      final controller = SessionController(
        repository: FakeRepository(),
        clock: () => time,
      );
      await controller.initialize();
      await controller.addSubject('Calculus', Priority.high);
      await controller.startPlan(
        tasks: const [FocusTask(id: 'a', subjectId: 1, title: 'Integrals')],
      );
      await controller.readyToFocus();
      final deadline = controller.active!.endsAt;
      final block = controller.active!.blockId;
      await tester.pumpWidget(NudgeApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byTooltip('Settings'), findsNothing);
      await tester.tap(find.byTooltip('Home'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Return to focus'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Calculus'))
            .onTap,
        isNull,
      );
      time = time.add(const Duration(minutes: 2));
      await controller.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Return to focus'));
      await tester.pumpAndSettle();
      expect(find.text('8:00'), findsOneWidget);
      expect(controller.active!.blockId, block);
      expect(controller.active!.endsAt, deadline);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('completion while on Home stays on Home and unlocks setup', (
    tester,
  ) async {
    var time = DateTime.utc(2026, 10, 31);
    final controller = SessionController(
      repository: FakeRepository(),
      clock: () => time,
    );
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    await controller.startPlan(
      tasks: const [FocusTask(id: 'a', subjectId: 1, title: 'Integrals')],
    );
    await controller.readyToFocus();
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    time = time.add(const Duration(minutes: 10));
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(controller.active, isNull);
    expect(controller.blocks, hasLength(1));
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('Choose study method'));
    await tester.pumpAndSettle();
    expect(find.text('How do you want to study Calculus?'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('saved study plan sheet shows the entire queue outside Home', (
    tester,
  ) async {
    final controller = SessionController(
      repository: FakeRepository(),
      clock: () => DateTime.utc(2026, 10, 31),
    );
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    for (var i = 0; i < 6; i++) {
      await controller.saveTask(
        FocusTask(id: '$i', subjectId: 1, title: 'Task $i'),
      );
    }
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Plan item options for Task 0'), findsNothing);
    expect(find.text('Task 4'), findsNothing);
    expect(find.text('Up next'), findsNothing);
    await tester.tap(find.byTooltip('Saved study plan'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Plan item options for Task 0'), findsOneWidget);
    expect(find.textContaining('10 min focus · 5 min break'), findsWidgets);
    await tester.tap(find.byTooltip('Plan item options for Task 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move plan item down'));
    await tester.pumpAndSettle();
    expect(controller.queue.first.title, 'Task 1');
    await tester.scrollUntilVisible(
      find.byTooltip('Plan item options for Task 5'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byTooltip('Plan item options for Task 5'), findsOneWidget);
    expect(controller.queue, hasLength(6));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('Custom sliders retain their values after switching presets', (
    tester,
  ) async {
    final controller = SessionController(
      repository: FakeRepository(),
      clock: () => DateTime.utc(2026, 10, 31),
    );
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose study method'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    final focus = find.byKey(const ValueKey('focus-minutes'));
    final rest = find.byKey(const ValueKey('break-minutes'));
    final focusSlider = tester.widget<Slider>(focus);
    final restSlider = tester.widget<Slider>(rest);
    expect((focusSlider.min, focusSlider.max), (1, 180));
    expect((restSlider.min, restSlider.max), (0, 60));
    focusSlider.onChanged!(37);
    restSlider.onChanged!(8);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Gentle Start'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(focus).value, 37);
    expect(tester.widget<Slider>(rest).value, 8);
    await tester.ensureVisible(find.text('Start preparation'));
    await tester.tap(find.text('Start preparation'));
    await tester.pumpAndSettle();
    expect(controller.active!.task!.config.focusMinutes, 37);
    expect(controller.active!.task!.config.breakMinutes, 8);
    expect(controller.active!.phase, SessionPhase.preparing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
