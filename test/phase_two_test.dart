import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/models.dart';
import 'package:nudge/session_controller.dart';
import 'package:nudge/focus_services.dart';

import 'fake_repository.dart';

class RecordingServices extends FocusServices {
  final calls = <ActiveSession?>[];
  @override
  Future<void> reconcile(ActiveSession? session, AppSettings settings) async {
    calls.add(session);
  }
}

void main() {
  late DateTime time;
  late FakeRepository repository;
  late RecordingServices services;
  late SessionController controller;
  const task = FocusTask(
    id: 'one',
    subjectId: 1,
    title: 'Integrals',
    config: TimerConfig(focusMinutes: 1, breakMinutes: 2, repeats: 2),
  );
  setUp(() async {
    time = DateTime.utc(2026, 10, 17);
    repository = FakeRepository();
    services = RecordingServices();
    controller = SessionController(
      repository: repository,
      services: services,
      clock: () => time,
    );
    await controller.initialize();
    await controller.addSubject('Math', Priority.high);
    await controller.addSubject('Writing', Priority.medium);
  });
  tearDown(() => controller.dispose());

  test(
    'preparation auto-starts once at its deadline and adds no preparation time',
    () async {
      await controller.startPlan(tasks: [task]);
      time = time.add(const Duration(seconds: 35));
      await Future.wait([
        controller.refresh(),
        controller.refresh(),
        controller.readyToFocus(),
      ]);
      expect(controller.active!.phase, SessionPhase.focus);
      expect(controller.remaining, const Duration(seconds: 55));
      expect(controller.totalSeconds(1), 0);
    },
  );
  test(
    'ready skips paused preparation; final focus ends without trailing break',
    () async {
      await controller.startPlan(
        tasks: [
          const FocusTask(
            id: 'a',
            subjectId: 1,
            title: 'Math',
            config: TimerConfig(focusMinutes: 1),
          ),
        ],
      );
      await controller.pauseSession();
      await Future.wait([controller.readyToFocus(), controller.readyToFocus()]);
      expect(controller.active!.phase, SessionPhase.focus);
      expect(controller.active!.isPaused, false);
      expect(controller.remaining, const Duration(minutes: 1));
      time = time.add(const Duration(minutes: 1));
      await controller.refresh();
      expect(controller.active, isNull);
      expect(controller.totalSeconds(1), 60);
      expect(services.calls.last, isNull);
    },
  );
  test('queue snapshots, repetition, and explicit next-task start', () async {
    await controller.saveTask(task);
    const writing = FocusTask(
      id: 'two',
      subjectId: 2,
      title: 'Essay',
      config: TimerConfig(focusMinutes: 3, breakMinutes: 0),
    );
    await controller.saveTask(writing);
    await controller.startPlan();
    await controller.readyToFocus();
    await controller.saveTask(
      const FocusTask(
        id: 'one',
        subjectId: 1,
        title: 'Changed',
        config: TimerConfig(focusMinutes: 90),
      ),
    );
    expect(controller.active!.task!.config.focusMinutes, 1);
    time = time.add(const Duration(minutes: 1));
    await controller.refresh();
    expect(controller.active!.phase, SessionPhase.rest);
    expect(controller.remaining, const Duration(minutes: 2));
    time = time.add(const Duration(hours: 1));
    await controller.refresh();
    expect(controller.active!.repeatIndex, 1);
    expect(controller.active!.phase, SessionPhase.rest);
    expect(controller.totalSeconds(1), 120);
    expect(controller.remaining, Duration.zero);
    expect(controller.queue.map((t) => t.id), ['two']);
    await controller.returnToStudy();
    expect(controller.active!.subjectId, 2);
    expect(controller.remaining, const Duration(minutes: 3));
    time = time.add(const Duration(minutes: 3));
    await controller.refresh();
    expect(controller.active, isNull);
    expect(controller.queue, isEmpty);
    expect(controller.totalSeconds(2), 180);
  });
  test(
    'opening settings freezes preparation and persists it across restart',
    () async {
      await controller.startPlan(tasks: [task]);
      time = time.add(const Duration(seconds: 10));
      await controller.pausePreparation();
      time = time.add(const Duration(hours: 2));
      await controller.refresh();
      expect(controller.remaining, const Duration(seconds: 20));
      final restored = SessionController(
        repository: repository,
        clock: () => time,
      );
      await restored.initialize();
      expect(restored.remaining, const Duration(seconds: 20));
      time = time.add(const Duration(seconds: 20));
      await restored.refresh();
      expect(restored.active!.phase, SessionPhase.focus);
      restored.dispose();
    },
  );
  test(
    'zero break still requires a tap; no phantom later tasks on restoration',
    () async {
      await controller.startPlan(
        tasks: [
          const FocusTask(
            id: 'a',
            subjectId: 1,
            title: 'First',
            config: TimerConfig(focusMinutes: 1, breakMinutes: 0),
          ),
          const FocusTask(id: 'b', subjectId: 2, title: 'Next'),
        ],
      );
      await controller.readyToFocus();
      time = time.add(const Duration(days: 1));
      final restored = SessionController(
        repository: repository,
        clock: () => time,
      );
      await restored.initialize();
      expect(restored.active!.phase, SessionPhase.rest);
      expect(restored.remaining, Duration.zero);
      expect(restored.blocks.length, 1);
      expect(restored.totalSeconds(2), 0);
      restored.dispose();
    },
  );
  test(
    'Pomodoro has a long fourth break only when another block remains',
    () async {
      await controller.startPlan(
        tasks: [
          const FocusTask(
            id: 'p',
            subjectId: 1,
            title: 'Practice',
            config: TimerConfig(
              focusMinutes: 1,
              breakMinutes: 5,
              repeats: 5,
              pomodoro: true,
            ),
          ),
        ],
      );
      await controller.readyToFocus();
      for (var i = 1; i <= 4; i++) {
        time = time.add(const Duration(minutes: 1));
        await controller.refresh();
        expect(controller.remaining, Duration(minutes: i == 4 ? 15 : 5));
        await controller.returnToStudy();
      }
      time = time.add(const Duration(minutes: 1));
      await controller.refresh();
      expect(controller.active, isNull);
      expect(controller.totalSeconds(1), 300);
    },
  );
  test(
    'early finish keeps unstarted tasks and only remaining repeats',
    () async {
      await controller.saveTask(task);
      await controller.saveTask(
        const FocusTask(id: 'two', subjectId: 2, title: 'Essay'),
      );
      await controller.startPlan();
      await controller.readyToFocus();
      time = time.add(const Duration(minutes: 1));
      await controller.refresh();
      await controller.returnToStudy();
      time = time.add(const Duration(seconds: 19));
      await controller.endSession();
      expect(controller.totalSeconds(1), 79);
      expect(controller.queue.first.config.repeats, 1);
      expect(controller.queue.last.id, 'two');
      expect(services.calls.last, isNull);
    },
  );
  test(
    'end at final deadline and cancellation are safe and idempotent',
    () async {
      await controller.startPlan(
        tasks: [
          const FocusTask(
            id: 'a',
            subjectId: 1,
            title: 'Math',
            config: TimerConfig(focusMinutes: 1),
          ),
        ],
      );
      await controller.readyToFocus();
      time = time.add(const Duration(minutes: 1));
      await controller.endSession();
      await controller.endSession();
      expect(controller.blocks.length, 1);
      await controller.startPlan(tasks: [task]);
      await controller.endSession();
      expect(controller.blocks.length, 1);
      expect(services.calls.last, isNull);
    },
  );
  test('failed end releases native controls and retry saves once', () async {
    await controller.startPlan(tasks: [task]);
    await controller.readyToFocus();
    time = time.add(const Duration(seconds: 15));
    repository.failSave = true;
    await controller.endSession();
    expect(services.calls.last, isNull);
    expect(controller.canAct, false);
    repository.failSave = false;
    await controller.retry();
    expect(controller.totalSeconds(1), 15);
    expect(repository.savedBlocks.length, 1);
  });
  test(
    'settings and queued tasks round-trip and reorder without changing history',
    () async {
      await controller.saveTask(task);
      await controller.saveTask(
        const FocusTask(id: 'two', subjectId: 2, title: 'Essay'),
      );
      await controller.moveTask(1, -1);
      await controller.updateSettings(
        controller.settings.copyWith(
          appearance: Appearance.dark,
          blockedApps: ['example.app'],
          intenseFocus: true,
          track: 1,
          volume: 0.25,
        ),
      );
      final json =
          jsonDecode(jsonEncode(repository.workspace.toJson()))
              as Map<String, dynamic>;
      final roundTrip = WorkspaceState.fromJson(json);
      expect(roundTrip.settings.appearance, Appearance.dark);
      expect(roundTrip.settings.blockedApps, ['example.app']);
      expect(roundTrip.queue.first.subjectId, 2);
      await controller.removeTask('one');
      expect(controller.queue.length, 1);
      expect(controller.blocks, isEmpty);
    },
  );
  test(
    'manual pause survives restart and excludes pauses from focus time',
    () async {
      await controller.startPlan(tasks: [task]);
      time = time.add(const Duration(seconds: 5));
      await controller.pauseSession();
      await controller.pausePreparation();
      await controller.resumePreparation();
      time = time.add(const Duration(minutes: 5));
      await controller.refresh();
      expect(controller.remaining, const Duration(seconds: 25));
      expect(controller.active!.phase, SessionPhase.preparing);
      await controller.resumeSession();
      await controller.readyToFocus();
      time = time.add(const Duration(seconds: 12));
      await controller.pauseSession();
      repository.active = ActiveSession.fromJson(repository.active!.toJson());
      time = time.add(const Duration(hours: 2));
      final restored = SessionController(
        repository: repository,
        clock: () => time,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.remaining, const Duration(seconds: 48));
      await restored.resumeSession();
      time = time.add(const Duration(seconds: 8));
      await restored.pauseSession();
      time = time.add(const Duration(hours: 1));
      await restored.endSession();
      expect(restored.totalSeconds(1), 20);
      expect(restored.blocks.single.completed, false);
    },
  );

  test('paused break keeps its time and then repeats automatically', () async {
    await controller.startPlan(tasks: [task]);
    await controller.readyToFocus();
    time = time.add(const Duration(seconds: 90));
    await controller.pauseSession();
    expect(controller.active!.phase, SessionPhase.rest);
    time = time.add(const Duration(hours: 1));
    await controller.refresh();
    await controller.returnToStudy();
    expect(controller.remaining, const Duration(seconds: 90));
    await controller.resumeSession();
    time = time.add(const Duration(seconds: 90));
    await controller.refresh();
    expect(controller.active!.repeatIndex, 1);
    expect(controller.remaining, const Duration(minutes: 1));
  });

  test('zero breaks catch up through all repeats once on restart', () async {
    await controller.startPlan(
      tasks: [
        const FocusTask(
          id: 'zero',
          subjectId: 1,
          title: 'Math',
          config: TimerConfig(focusMinutes: 1, breakMinutes: 0, repeats: 3),
        ),
      ],
    );
    final firstFocus = time.add(const Duration(seconds: 30));
    expect(
      controller.active!.protectionDeadline,
      firstFocus.add(const Duration(minutes: 3)),
    );
    time = time.add(const Duration(hours: 1));
    final restored = SessionController(
      repository: repository,
      clock: () => time,
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    await restored.refresh();
    expect(restored.active, isNull);
    expect(restored.totalSeconds(1), 180);
    expect(restored.blocks.map((b) => b.startedAt), [
      firstFocus.add(const Duration(minutes: 2)),
      firstFocus.add(const Duration(minutes: 1)),
      firstFocus,
    ]);
    expect(repository.savedBlocks.length, 3);
  });

  test('invalid task durations cannot mutate the queue', () async {
    await expectLater(
      controller.saveTask(
        const FocusTask(
          id: 'bad',
          subjectId: 1,
          title: 'Bad',
          config: TimerConfig(focusMinutes: 0),
        ),
      ),
      throwsArgumentError,
    );
    expect(controller.queue, isEmpty);
    expect(controller.busy, false);
  });
  test(
    'a late return action persists final expiry even when no next task exists',
    () async {
      await controller.startPlan(
        tasks: [
          const FocusTask(
            id: 'only',
            subjectId: 1,
            title: 'Final task',
            config: TimerConfig(focusMinutes: 1),
          ),
        ],
      );
      await controller.readyToFocus();
      time = time.add(const Duration(minutes: 1));
      await controller.returnToStudy();
      expect(repository.active, isNull);
      expect(repository.savedBlocks.length, 1);
      expect(controller.totalSeconds(1), 60);
    },
  );
}
