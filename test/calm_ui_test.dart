import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/nudge_theme.dart';
import 'package:nudge/focus_widgets.dart';
import 'package:nudge/focus_services.dart';
import 'package:nudge/models.dart';
import 'package:nudge/session_controller.dart';

import 'fake_repository.dart';

class PlaybackServices extends FocusServices {
  final actions = <String>[];
  @override
  Future<void> music(String action, {int? track, double? volume}) async {
    actions.add(action);
    if (action == 'toggle' || action == 'preview') playing = !playing;
    notifyListeners();
  }
}

class PermissionServices extends FocusServices {
  final returned = Completer<void>();
  PermissionServices() {
    status = const ProtectionStatus(
      supported: true,
      dndAccess: true,
      alarmAccess: true,
    );
  }
  @override
  Future<void> openPermission(String permission) async {
    await returned.future;
    status = const ProtectionStatus(
      supported: true,
      dndAccess: true,
      alarmAccess: true,
      blockingAccess: true,
    );
  }
}

void main() {
  testWidgets('study panels collapse without stopping or resetting music', (
    tester,
  ) async {
    final audio = PlaybackServices()
      ..duration = const Duration(minutes: 3)
      ..position = const Duration(seconds: 35)
      ..seekable = true
      ..playing = true;
    final controller = SessionController(
      repository: FakeRepository(),
      services: audio,
      clock: () => DateTime.utc(2026),
    );
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    await controller.updateSettings(controller.settings.copyWith(track: 0));
    await controller.startFocus(1);
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-seek')), findsNothing);
    expect(find.text('Intense Focus'), findsNothing);
    final music = find.text('Music');
    await tester.scrollUntilVisible(music, 120);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pause music'));
    await tester.pumpAndSettle();
    expect(audio.playing, false);
    await tester.tap(music);
    await tester.pumpAndSettle();
    final seek = find.byKey(const ValueKey('music-seek'));
    expect(tester.widget<Slider>(seek).value, 35000);
    await tester.tap(music);
    await tester.pumpAndSettle();
    expect(seek, findsNothing);
    expect(audio.position.inSeconds, 35);
    expect(audio.actions, ['toggle']);
    await tester.scrollUntilVisible(find.text('Protection'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Protection'));
    await tester.pumpAndSettle();
    expect(find.text('Intense Focus'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('task menu offers edit and delete, with one Add task entry', (
    tester,
  ) async {
    final controller = SessionController(repository: FakeRepository());
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(PopupMenuItem<String>, 'Add task'),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Task options for Calculus'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(PopupMenuItem<String>, 'Add task'),
      findsNothing,
    );
    expect(find.text('Edit task'), findsOneWidget);
    expect(find.text('Delete task'), findsOneWidget);
    expect(controller.queue, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('closing an expanded settings music preview stops it', (
    tester,
  ) async {
    final audio = PlaybackServices();
    final controller = SessionController(
      repository: FakeRepository(),
      services: audio,
    );
    await controller.initialize();
    await controller.updateSettings(controller.settings.copyWith(track: 0));
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byTooltip('Play music'), 150);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play music'));
    await tester.pumpAndSettle();
    expect(audio.actions, contains('preview'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(audio.actions.last, 'stopPreview');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('offscreen task fields still validate before saving', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SessionController(repository: FakeRepository());
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    await tester.pumpWidget(
      MaterialApp(
        theme: NudgeTheme.build(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: PlanItemDialog(
          subjects: controller.subjects,
          controller: controller,
          existing: const FocusTask(
            id: 'existing',
            subjectId: 1,
            title: 'Notes',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = find.widgetWithText(TextFormField, 'Plan item name');
    await tester.scrollUntilVisible(
      title,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(title, '');
    await tester.scrollUntilVisible(
      find.text('Custom'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    final focus = find.byKey(const ValueKey('focus-minutes'));
    await tester.scrollUntilVisible(
      focus,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(focus).divisions, 179);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.scrollUntilVisible(
      find.text('Save plan item'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save plan item'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Enter a plan item name.'), findsOneWidget);
    expect(controller.queue, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('setup permission controls scroll with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = PermissionServices()
      ..status = const ProtectionStatus(supported: true);
    final controller = SessionController(
      repository: FakeRepository(),
      services: services,
      clock: () => DateTime.utc(2026),
    );
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    await controller.saveTask(
      const FocusTask(id: 'one', subjectId: 1, title: 'Read notes'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NudgeTheme.build(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: StudyHome(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Saved study plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start saved plan'));
    await tester.pumpAndSettle();
    expect(find.text('Study plan setup'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('Make room for focus'), findsOneWidget);
    expect(
      find.text('Allow Do Not Disturb to quiet notifications while you study.'),
      findsOneWidget,
    );
    expect(find.textContaining('precise timer endings'), findsNothing);
    await tester.ensureVisible(find.text('Allow DND'));
    expect(find.text('Allow timer endings'), findsOneWidget);
    expect(controller.active, isNull);
    final start = find.text('Start preparation');
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(controller.active!.phase, SessionPhase.preparing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('theme text and action contrast remains readable', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
    }

    for (final brightness in Brightness.values) {
      final theme = NudgeTheme.build(brightness), colors = theme.colorScheme;
      expect(
        contrast(colors.onSurface, colors.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.onSurfaceVariant, theme.scaffoldBackgroundColor),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.onPrimary, colors.primary),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  for (final brightness in Brightness.values) {
    for (final large in [false, true]) {
      testWidgets(
        'all screens remain reachable in $brightness, large text $large',
        (tester) async {
          tester.view.physicalSize = large
              ? const Size(320, 568)
              : const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var time = DateTime.utc(2026);
          final controller = SessionController(
            repository: FakeRepository(),
            clock: () => time,
          );
          await controller.initialize();
          await controller.addSubject(
            'A long subject name for narrow screens',
            Priority.high,
          );
          await controller.updateSettings(
            controller.settings.copyWith(track: 0),
          );
          await controller.saveTask(
            const FocusTask(
              id: 'one',
              subjectId: 1,
              title: 'A thoughtful task with a long descriptive title',
              config: TimerConfig(repeats: 2),
            ),
          );
          Future<void> screen(Widget child) async {
            await tester.pumpWidget(
              MaterialApp(
                key: UniqueKey(),
                theme: NudgeTheme.build(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(large ? 2 : 1),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: child,
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }

          Future<void> reach(Finder target) async {
            await tester.scrollUntilVisible(
              target,
              120,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.ensureVisible(target);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }

          await screen(StudyHome(controller: controller));
          await reach(find.text('Add task'));
          await screen(
            PlanItemDialog(
              controller: controller,
              subjects: controller.subjects,
              existing: controller.queue.single,
            ),
          );
          await reach(find.text('Save plan item'));
          await screen(
            Scaffold(
              body: Center(child: StudyTaskDialog(controller: controller)),
            ),
          );
          await tester.enterText(find.byType(TextFormField), 'New task');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await screen(SettingsScreen(controller: controller));
          await reach(find.byKey(const ValueKey('music-volume')));
          await reach(find.text('About'));
          await tester.tap(find.text('About'));
          await tester.pumpAndSettle();
          await reach(find.text('Music credits'));
          await controller.startPlan();
          await screen(StudyHome(controller: controller));
          expect(find.text('0:30'), findsOneWidget);
          time = time.add(const Duration(seconds: 30));
          await controller.refresh();
          await tester.pumpAndSettle();
          expect(controller.active!.phase, SessionPhase.focus);
          await reach(find.text('Music'));
          await tester.tap(find.text('Music'));
          await tester.pumpAndSettle();
          await reach(find.byKey(const ValueKey('music-volume')));
          await reach(find.text('Protection'));
          await tester.tap(find.text('Protection'));
          await tester.pumpAndSettle();
          time = time.add(const Duration(minutes: 10));
          await controller.refresh();
          await tester.pumpAndSettle();
          expect(controller.active!.phase, SessionPhase.rest);
          await reach(find.text('Next session'));
          await tester.tap(find.text('Next session'));
          await tester.pumpAndSettle();
          expect(controller.active!.phase, SessionPhase.focus);
          await reach(find.text('Finish'));
          await tester.tap(find.text('Finish'));
          await tester.pumpAndSettle();
          expect(controller.active, isNull);
          await tester.tap(find.text('History'));
          await tester.pumpAndSettle();
          expect(find.text('Study time'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        },
      );
    }
  }
}
