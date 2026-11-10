import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/models.dart';
import 'package:nudge/session_controller.dart';

import 'fake_repository.dart';

void main() {
  late DateTime time;
  late FakeRepository repository;
  late SessionController controller;

  setUp(() async {
    time = DateTime.utc(2026, 10, 12, 12);
    repository = FakeRepository();
    controller = SessionController(repository: repository, clock: () => time);
    await controller.initialize();
    await controller.addSubject('Calculus', Priority.high);
  });

  tearDown(() => controller.dispose());

  test('focus deadline starts a break anchored to its scheduled end', () async {
    await controller.startFocus(1);
    time = time.add(const Duration(minutes: 12));
    await controller.refresh();
    expect(controller.active!.phase, SessionPhase.rest);
    expect(controller.remaining, const Duration(minutes: 3));
    expect(controller.totalSeconds(1), 600);
    expect(repository.savedBlocks.length, 1);
    await controller.refresh();
    expect(repository.savedBlocks.length, 1);
  });

  test(
    'reopen after both deadlines waits, without inventing study time',
    () async {
      await controller.startFocus(1);
      time = time.add(const Duration(hours: 2));
      final restored = SessionController(
        repository: repository,
        clock: () => time,
      );
      await restored.initialize();
      expect(restored.active!.phase, SessionPhase.rest);
      expect(restored.remaining, Duration.zero);
      expect(restored.totalSeconds(1), 600);
      await restored.refresh();
      expect(restored.active!.phase, SessionPhase.rest);
      await restored.returnToStudy();
      expect(restored.active!.phase, SessionPhase.focus);
      expect(restored.remaining, const Duration(minutes: 10));
      restored.dispose();
    },
  );

  test('reopen during focus and break uses saved timestamps', () async {
    await controller.startFocus(1);
    time = time.add(const Duration(minutes: 4));
    final duringFocus = SessionController(
      repository: repository,
      clock: () => time,
    );
    await duringFocus.initialize();
    expect(duringFocus.remaining, const Duration(minutes: 6));
    duringFocus.dispose();
    time = time.add(const Duration(minutes: 7));
    await controller.refresh();
    final duringBreak = SessionController(
      repository: repository,
      clock: () => time,
    );
    await duringBreak.initialize();
    expect(duringBreak.active!.phase, SessionPhase.rest);
    expect(duringBreak.remaining, const Duration(minutes: 4));
    duringBreak.dispose();
  });

  test('early return and rapid taps start only one new focus block', () async {
    await controller.startFocus(1);
    time = time.add(const Duration(minutes: 10));
    await controller.refresh();
    time = time.add(const Duration(minutes: 1));
    final before = repository.commits;
    await Future.wait([controller.returnToStudy(), controller.returnToStudy()]);
    expect(repository.commits, before + 1);
    expect(controller.remaining, const Duration(minutes: 10));
    expect(controller.totalSeconds(1), 600);
  });

  test('ending partial focus logs seconds but not break time', () async {
    await controller.startFocus(1);
    time = time.add(const Duration(seconds: 91));
    await controller.endSession();
    expect(controller.active, isNull);
    expect(controller.totalSeconds(1), 91);
    expect(controller.blocks.single.completed, isFalse);
    await controller.startFocus(1);
    time = time.add(const Duration(minutes: 14));
    await controller.endSession();
    expect(controller.totalSeconds(1), 691);
    expect(repository.active, isNull);
  });

  test(
    'failed transition stays in memory and retry commits exactly once',
    () async {
      await controller.startFocus(1);
      repository.failSave = true;
      time = time.add(const Duration(minutes: 10));
      await controller.refresh();
      expect(controller.error, contains('only in memory'));
      expect(controller.canAct, isFalse);
      expect(controller.active!.phase, SessionPhase.rest);
      expect(controller.totalSeconds(1), 600);
      expect(repository.savedBlocks, isEmpty);
      await controller.returnToStudy();
      expect(controller.active!.phase, SessionPhase.rest);
      repository.failSave = false;
      await controller.retry();
      expect(controller.error, isNull);
      expect(repository.savedBlocks.length, 1);
      await controller.retry();
      expect(controller.totalSeconds(1), 600);
      expect(repository.savedBlocks.length, 1);
    },
  );

  test('failed start and failed end can both be retried', () async {
    repository.failSave = true;
    await controller.startFocus(1);
    expect(controller.active, isNotNull);
    expect(repository.active, isNull);
    repository.failSave = false;
    await controller.retry();
    expect(repository.active, isNotNull);
    time = time.add(const Duration(seconds: 45));
    repository.failSave = true;
    await controller.endSession();
    expect(controller.active, isNull);
    expect(controller.totalSeconds(1), 45);
    repository.failSave = false;
    await controller.retry();
    expect(repository.active, isNull);
    expect(repository.savedBlocks.values.single.focusSeconds, 45);
  });

  test(
    'loading failure provides a retry without resetting stored data',
    () async {
      repository.failLoad = true;
      final restored = SessionController(
        repository: repository,
        clock: () => time,
      );
      await restored.initialize();
      expect(restored.ready, isFalse);
      expect(restored.error, isNotNull);
      repository.failLoad = false;
      await restored.retry();
      expect(restored.subjects.single.name, 'Calculus');
      restored.dispose();
    },
  );

  test('subjects sort by manual priority and trim names', () async {
    await controller.addSubject('  Geology  ', Priority.low);
    await controller.addSubject('Writing', Priority.medium);
    expect(controller.subjects.map((s) => s.name), [
      'Calculus',
      'Writing',
      'Geology',
    ]);
    await controller.editSubject(2, '  Earth science ', Priority.high);
    expect(controller.subjects.map((s) => s.id), [1, 2, 3]);
    expect(controller.subject(2).name, 'Earth science');
    await expectLater(
      controller.addSubject('   ', Priority.low),
      throwsArgumentError,
    );
  });

  test(
    'subject save failure keeps existing data and releases busy lock',
    () async {
      repository.failSubjects = true;
      await expectLater(
        controller.addSubject('Physics', Priority.low),
        throwsStateError,
      );
      expect(controller.busy, isFalse);
      expect(controller.subjects.length, 1);
      repository.failSubjects = false;
      await controller.addSubject('Physics', Priority.low);
      expect(controller.subjects.length, 2);
    },
  );

  test('clock moving backward never creates negative focus time', () async {
    await controller.startFocus(1);
    time = time.subtract(const Duration(minutes: 1));
    await controller.endSession();
    expect(controller.blocks, isEmpty);
  });

  test('countdown rounds up and minutes preserve partial study time', () {
    expect(formatCountdown(const Duration(milliseconds: 599999)), '10:00');
    expect(formatCountdown(Duration.zero), '0:00');
    expect(formatMinutes(91), '1.5');
  });
}
