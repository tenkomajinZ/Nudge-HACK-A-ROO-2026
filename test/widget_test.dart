import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/focus_widgets.dart';
import 'package:nudge/focus_services.dart';
import 'package:nudge/models.dart';
import 'package:nudge/session_controller.dart';

import 'fake_repository.dart';

class SeekingServices extends FocusServices {
  final seeks = <Duration>[];
  void tick(Duration value) {
    position = value;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position, {required int track}) async {
    seeks.add(position);
    tick(position);
  }
}

class VolumeServices extends FocusServices {
  final volumes = <double>[];
  int reconciles = 0;
  @override
  Future<void> setVolume(double value) async {
    volumes.add(value);
  }

  @override
  Future<void> reconcile(ActiveSession? session, AppSettings settings) async {
    reconciles++;
  }
}

class DelayedVolumeRepository extends FakeRepository {
  Completer<void>? nextCommit;
  @override
  Future<void> commit(
    ActiveSession? active,
    List<StudyBlock> newBlocks, {
    WorkspaceState? workspace,
  }) async {
    final gate = nextCommit;
    nextCommit = null;
    if (gate != null) await gate.future;
    await super.commit(active, newBlocks, workspace: workspace);
  }
}

void main() {
  testWidgets(
    'rapid volume drags keep the latest level during a delayed save',
    (tester) async {
      final repository = DelayedVolumeRepository();
      final audio = VolumeServices();
      final controller = SessionController(
        repository: repository,
        services: audio,
      );
      await controller.initialize();
      await controller.updateSettings(controller.settings.copyWith(track: 0));
      final initialReconciles = audio.reconciles;
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (_, _) => MaterialApp(
            home: Scaffold(body: MusicPanel(controller: controller)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('music-volume'));
      final rect = tester.getRect(slider);
      final gate = Completer<void>();
      repository.nextCommit = gate;
      final first = await tester.startGesture(rect.center);
      await first.moveTo(Offset(rect.left, rect.center.dy));
      await first.up();
      await tester.pump();
      expect(controller.busy, true);
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      final second = await tester.startGesture(rect.center);
      await second.moveTo(Offset(rect.right, rect.center.dy));
      await tester.pump();
      final latest = tester.widget<Slider>(slider).value;
      expect(latest, closeTo(1, 0.01));
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, latest);
      expect(audio.volumes.last, latest);
      await second.up();
      await tester.pumpAndSettle();
      expect(repository.workspace.settings.volume, latest);
      expect(
        audio.reconciles,
        initialReconciles,
        reason: 'Volume saves must not restart/synchronize playback.',
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('music thumb stays under the finger and seeks once on release', (
    tester,
  ) async {
    final audio = SeekingServices()
      ..duration = const Duration(minutes: 3)
      ..position = const Duration(seconds: 10)
      ..seekable = true;
    final controller = SessionController(
      repository: FakeRepository(),
      services: audio,
    );
    await controller.initialize();
    await controller.updateSettings(controller.settings.copyWith(track: 0));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MusicPanel(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('music-seek'));
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(
      Offset(rect.left + rect.width * 0.1, rect.center.dy),
    );
    await gesture.moveTo(Offset(rect.left + rect.width * 0.75, rect.center.dy));
    await tester.pump();
    final dragged = tester.widget<Slider>(slider).value;
    audio.tick(const Duration(seconds: 11));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, dragged);
    expect(audio.seeks, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(audio.seeks, hasLength(1));
    expect(audio.seeks.single.inMilliseconds, closeTo(dragged, 1));
    expect(audio.seeks.single.inSeconds, greaterThan(90));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('empty state, blank validation, add and rename a subject', (
    tester,
  ) async {
    final controller = SessionController(
      repository: FakeRepository(),
      clock: () => DateTime.utc(2026),
    );
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('One small start.'), findsOneWidget);
    await tester.tap(find.text('Add task'));
    await tester.pumpAndSettle();
    expect(find.text('Priority'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter a task name.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'Calculus');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Calculus'), findsOneWidget);
    expect(controller.subjects.single.priority, Priority.medium);
    await tester.tap(find.byTooltip('Task options for Calculus'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Calculus 2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Calculus 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('preparation resumes and starts focus automatically', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var time = DateTime.utc(2026);
    final controller = SessionController(
      repository: FakeRepository(),
      clock: () => time,
    );
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
    await controller.startPlan(
      tasks: [
        const FocusTask(id: 'task', subjectId: 1, title: 'Practice integrals'),
      ],
    );
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Phone is out of reach'), findsNothing);
    expect(find.text('Do Not Disturb is on'), findsNothing);
    expect(find.text('0:30'), findsOneWidget);
    final preparationCue = find.text(
      'Take a sip of water.\nBreathe in slowly, then breathe out.',
    );
    expect(preparationCue, findsOneWidget);
    final skip = find.widgetWithText(OutlinedButton, 'Skip preparation');
    await tester.ensureVisible(skip);
    await tester.pumpAndSettle();
    expect(skip.hitTestable(), findsOneWidget);
    expect(find.text('Choose study method'), findsNothing);
    final pause = find.descendant(
      of: find.byType(CountdownRing),
      matching: find.byTooltip('Pause timer'),
    );
    expect(pause, findsOneWidget);
    expect(
      find.descendant(of: pause, matching: find.byIcon(Icons.pause_rounded)),
      findsOneWidget,
    );
    await tester.ensureVisible(pause);
    await tester.pumpAndSettle();
    await tester.tap(pause.hitTestable());
    await tester.pumpAndSettle();
    time = time.add(const Duration(seconds: 30));
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(controller.active!.phase, SessionPhase.preparing);
    expect(find.text('0:30'), findsOneWidget);
    final resume = find.descendant(
      of: find.byType(CountdownRing),
      matching: find.byTooltip('Resume timer'),
    );
    expect(resume, findsOneWidget);
    expect(
      find.descendant(
        of: resume,
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );
    await tester.tap(resume);
    await tester.pumpAndSettle();
    time = time.add(const Duration(seconds: 30));
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(controller.active!.phase, SessionPhase.focus);
    expect(find.text('10:00'), findsOneWidget);
    expect(preparationCue, findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('small screen with large text can scroll and return from break', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var time = DateTime.utc(2026);
    final repository = FakeRepository();
    final controller = SessionController(
      repository: repository,
      clock: () => time,
    );
    await controller.initialize();
    await controller.addSubject(
      'A very long subject name for checking narrow screens',
      Priority.high,
    );
    await controller.startFocus(1);
    time = time.add(const Duration(minutes: 20));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: StudyHome(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.active!.phase, SessionPhase.rest);
    await tester.scrollUntilVisible(
      find.text('Break over'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Break over'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Continue'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('Continue')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(controller.active!.phase, SessionPhase.focus);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('storage load failure exposes retry', (tester) async {
    final repository = FakeRepository()..failLoad = true;
    final controller = SessionController(repository: repository);
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    repository.failLoad = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Add task'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('new focus screen starts at the top after browsing subjects', (
    tester,
  ) async {
    final controller = SessionController(
      repository: FakeRepository(),
      clock: () => DateTime.utc(2026),
    );
    await controller.initialize();
    for (var index = 0; index < 12; index++) {
      await controller.addSubject('Subject $index', Priority.medium);
    }
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      greaterThan(0),
    );
    await controller.startFocus(1);
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      0,
    );
    expect(find.text('Subject 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
    'editing a saved plan item preserves fixed Pomodoro lengths and a custom session count',
    (tester) async {
      final controller = SessionController(
        repository: FakeRepository(),
        clock: () => DateTime.utc(2026),
      );
      await controller.initialize();
      await controller.addSubject('Calculus', Priority.high);
      await controller.saveTask(
        const FocusTask(id: 'saved', subjectId: 1, title: 'Calculus'),
      );
      await tester.pumpWidget(NudgeApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Saved study plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Plan item options for Calculus'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit plan item'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Pomodoro'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      final increase = find.byTooltip('Add a session');
      await tester.ensureVisible(increase);
      await tester.tap(increase);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Save plan item'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save plan item'));
      await tester.pumpAndSettle();
      final config = controller.queue.single.config;
      expect(config.pomodoro, false);
      expect(config.focusMinutes, 25);
      expect(config.breakMinutes, 5);
      expect(config.repeats, 2);

      await tester.tap(find.byTooltip('Plan item options for Calculus'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit plan item'));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Pomodoro'))
            .selected,
        true,
      );
      await tester.ensureVisible(increase);
      for (var count = 2; count < 12; count++) {
        await tester.tap(increase);
        await tester.pump();
      }
      expect(find.text('12'), findsOneWidget);
      final addButton = find.widgetWithIcon(IconButton, Icons.add_rounded);
      expect(tester.widget<IconButton>(addButton).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets('music volume drag persists the final selected value', (
    tester,
  ) async {
    final repository = FakeRepository();
    final audio = VolumeServices();
    final controller = SessionController(
      repository: repository,
      services: audio,
    );
    await controller.initialize();
    await controller.updateSettings(controller.settings.copyWith(track: 0));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MusicPanel(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('music-volume'));
    final rectangle = tester.getRect(slider);
    final gesture = await tester.startGesture(rectangle.center);
    await gesture.moveBy(Offset(-rectangle.width, 0));
    await tester.pump();
    expect(
      audio.volumes,
      isNotEmpty,
      reason: 'Dragging must change the sound before release.',
    );
    expect(audio.volumes.last, closeTo(0, 0.01));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.settings.volume, closeTo(0, 0.01));
    expect(repository.workspace.settings.volume, closeTo(0, 0.01));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
