// Capture Flutter-rendered phase-two screens using a simulated clock.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_gateway.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/session_controller.dart';

import '../test/fake_repository.dart';

void main() {
  testWidgets('capture phase-two screens using simulated time', (tester) async {
    final previousShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = previousShadows);
    await tester.runAsync(() async {
      final directory =
          '${Platform.environment['NUDGE_FLUTTER_SDK']!}/bin/cache/artifacts/material_fonts';
      final font = FontLoader('Roboto');
      for (final weight in ['regular', 'medium', 'bold']) {
        font.addFont(
          File(
            '$directory/roboto-$weight.ttf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      }
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '$directory/materialicons-regular.otf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await icons.load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var time = DateTime.utc(2026, 10, 31, 12);
    final controller = SessionController(
      repository: FakeRepository(),
      clock: () => time,
      recallGateway: SampleRecallGateway(),
    );
    await controller.initialize();
    await controller.addSubject('Calculus 2', Priority.high);
    await controller.addSubject('Creative writing', Priority.medium);
    await controller.saveTask(
      const FocusTask(
        id: 'math',
        subjectId: 1,
        title: 'Practice integration',
        config: TimerConfig(focusMinutes: 25, repeats: 2, pomodoro: true),
      ),
    );
    await controller.saveTask(
      const FocusTask(id: 'writing', subjectId: 2, title: 'Outline my essay'),
    );
    final boundary = GlobalKey();
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('demo-output')..createSync();
        File(
          '${directory.path}/$name',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: NudgeApp(controller: controller),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/branding/nudge-mark.png'),
        tester.element(find.byType(StudyHome)),
      ),
    );
    await controller.updateSettings(
      controller.settings.copyWith(track: 0, volume: .35),
    );
    controller.services.duration = const Duration(minutes: 4);
    controller.services.seekable = true;
    await capture('phase2-plan-light.png');
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.dark),
    );
    await capture('focus-home-dark.png');
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.light),
    );
    final studyCalculus = find.widgetWithText(ListTile, 'Calculus 2');
    await tester.scrollUntilVisible(studyCalculus, 120);
    await tester.pumpAndSettle();
    await tester.tap(studyCalculus);
    await tester.pumpAndSettle();
    final startStudy = find.text('Choose study method');
    await tester.ensureVisible(startStudy);
    await tester.tap(startStudy);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Focus'));
    await capture('calm-task-light.png');
    await tester.tap(find.text('Custom'));
    await capture('focus-custom-light.png');
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.dark),
    );
    await capture('focus-custom-dark.png');
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.light),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Add task'), 150);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add task'));
    await capture('calm-subject-light.png');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await capture('calm-settings-light.png');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await controller.startPlan();
    await capture('phase2-prepare-light.png');
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.dark),
    );
    await capture('focus-prepare-dark.png');
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.light),
    );
    await controller.readyToFocus();
    controller.services.playing = true;
    controller.services.position = const Duration(seconds: 45);
    time = time.add(const Duration(minutes: 8));
    await controller.refresh();
    await capture('phase2-focus-light.png');
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.dark),
    );
    await capture('phase2-focus-dark.png');
    await controller.pauseSession();
    await capture('focus-paused-dark.png');
    await controller.resumeSession();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Home'));
    await capture('focus-resume-dark.png');
    await tester.tap(find.text('Return to focus'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Music'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Music'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Music'));
    await capture('calm-music-dark.png');
    await tester.tap(find.text('Music'));
    await tester.pumpAndSettle();
    time = time.add(const Duration(minutes: 17));
    await controller.refresh();
    await capture('phase2-break-dark.png');
    await controller.endSession();
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await capture('phase2-history-dark.png');
    await tester.tap(find.byTooltip('Settings'));
    await capture('calm-settings-dark.png');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.light),
    );
    await capture('calm-history-light.png');
    await tester.tap(find.text('Home'));
    for (final task in List<FocusTask>.of(controller.queue)) {
      await controller.removeTask(task.id);
    }
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await tester.pumpAndSettle();
    await capture('calm-subjects-light.png');
    await controller.updateSettings(
      controller.settings.copyWith(appearance: Appearance.dark),
    );
    await capture('calm-subjects-dark.png');
    for (final brightness in [Appearance.dark, Appearance.light]) {
      await controller.updateSettings(
        controller.settings.copyWith(appearance: brightness),
      );
      await controller.startPlan(
        tasks: const [
          FocusTask(
            id: 'accessibility',
            subjectId: 1,
            title: 'Practice integration',
          ),
        ],
      );
      // Return to immersive presentation after explicitly visiting Home earlier.
      await tester.pumpAndSettle();
      if (find.text('Return to focus').evaluate().isNotEmpty) {
        await tester.tap(find.text('Return to focus'));
      }
      await controller.readyToFocus();
      for (final large in [false, true]) {
        tester.view.physicalSize = large
            ? const Size(320, 568)
            : const Size(844, 390);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MediaQuery(
              data: MediaQueryData(
                size: large ? const Size(320, 568) : const Size(844, 390),
                textScaler: TextScaler.linear(large ? 2 : 1),
                disableAnimations: true,
              ),
              child: NudgeApp(controller: controller),
            ),
          ),
        );
        await capture(
          'focus-${brightness.name}-${large ? 'large-text' : 'landscape'}.png',
        );
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: NudgeApp(controller: controller),
        ),
      );
      await controller.endSession();
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
    }
    for (final brightness in [Appearance.light, Appearance.dark]) {
      await controller.updateSettings(
        controller.settings.copyWith(appearance: brightness),
      );
      await controller.startPlan(
        tasks: const [
          FocusTask(
            id: 'recall',
            subjectId: 1,
            title: 'Recall practice',
            material: RecallMaterial.sample,
          ),
        ],
      );
      await controller.readyToFocus();
      time = time.add(const Duration(seconds: 10));
      await tester.runAsync(controller.refresh);
      await controller.endSession();
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      await capture('focus-recall-choice-${brightness.name}.png');
      await controller.startRecall();
      await capture('focus-recall-answer-${brightness.name}.png');
      await tester.tap(find.text('Questions'));
      await capture('recall-question-list-${brightness.name}.png');
      await tester.tap(find.byTooltip('Close question list'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1024, 768);
      await capture('recall-sidebar-${brightness.name}.png');
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      final early = find.text('Hold to submit early');
      await tester.scrollUntilVisible(
        early,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(early);
      await tester.pumpAndSettle();
      final hold = await tester.startGesture(tester.getCenter(early));
      await tester.pump(const Duration(seconds: 2));
      await hold.up();
      await capture('recall-submit-confirmation-${brightness.name}.png');
      await tester.tap(find.text('Keep answering'));
      await tester.pumpAndSettle();
      for (final question in controller.recallRun!.quiz!.questions) {
        for (final part in question.parts) {
          await controller.setRecallAnswer(
            '${question.id}/${part.id}',
            part.kind == 'choice'
                ? (question.id == 'q1'
                      ? part.correct
                      : part.options.keys.firstWhere(
                          (key) => key != part.correct,
                        ))
                : 'wrong',
          );
        }
        await controller.checkRecallAnswer(question.id);
        if (question.id == 'q1' || question.id == 'q3') {
          await tester.pumpAndSettle();
          final feedback = find.text(
            question.id == 'q1' ? 'Good job!' : question.explanation,
          );
          await tester.scrollUntilVisible(
            feedback,
            160,
            scrollable: find.byType(Scrollable).first,
          );
          await Scrollable.ensureVisible(
            tester.element(feedback),
            alignment: 0.9,
          );
          await capture(
            'recall-${question.id == 'q1' ? 'correct' : 'incorrect'}-${brightness.name}.png',
          );
        }
        await controller.nextRecallQuestion(question.id);
      }
      await controller.submitRecall(runId: controller.recallRun!.id);
      await capture('focus-recall-result-${brightness.name}.png');
      await controller.finishRecall();
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox());
    final empty = SessionController(repository: FakeRepository());
    await empty.initialize();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: NudgeApp(controller: empty),
      ),
    );
    await capture('focus-empty-light.png');
    await empty.updateSettings(
      empty.settings.copyWith(appearance: Appearance.dark),
    );
    await capture('focus-empty-dark.png');
    await tester.pumpWidget(const SizedBox());
    empty.dispose();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    debugDisableShadows = previousShadows;
  });
}
