import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/recall_gateway.dart';
import 'package:nudge/session_controller.dart';
import 'fake_repository.dart';

class DeferredRecall extends SampleRecallGateway {
  final result = Completer<RecallJob>();
  String? requested;
  @override
  Future<RecallJob> submit(
    RecallMaterial material,
    String requestId,
    List<String> missed, {
    bool retry = false,
    List<String> previous = const [],
  }) {
    requested = requestId;
    return result.future;
  }
}

class RecoveringRecall extends SampleRecallGateway {
  String? failure = 'Recall service is unavailable';
  @override
  Future<RecallJob> submit(
    RecallMaterial material,
    String requestId,
    List<String> missed, {
    bool retry = false,
    List<String> previous = const [],
  }) async {
    if (failure != null) throw StateError(failure!);
    return super.submit(
      material,
      requestId,
      missed,
      retry: retry,
      previous: previous,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const task = FocusTask(
    id: 'task',
    subjectId: 1,
    title: 'Demo',
    material: RecallMaterial.sample,
  );

  test(
    'manual retry saves the current failure and recovers the same attempt',
    () async {
      final repo = FakeRepository();
      final gateway = RecoveringRecall();
      final c = SessionController(repository: repo, recallGateway: gateway);
      await c.initialize();
      await c.addSubject('Demo', Priority.medium);
      await c.startPlan(tasks: [task]);
      await c.pollRecall();
      final requestId = c.recallRun!.entries.single.requestId;
      expect(c.recallRun!.entries.single.error, contains('unavailable'));
      gateway.failure = 'Live generation is disabled';
      await c.retryRecall();
      expect(c.recallRun!.entries.single.error, contains('disabled'));
      expect(
        repo.workspace.recall.current!.entries.single.error,
        contains('disabled'),
      );
      gateway.failure = null;
      await c.retryRecall();
      expect(c.recallRun!.entries.single.requestId, requestId);
      expect(c.recallRun!.entries.single.state, 'ready');
      expect(c.recallRun!.entries.single.error, isNull);
      c.dispose();
    },
  );

  test('late generation cannot replace a finished or newer run', () async {
    final gateway = DeferredRecall();
    final c = SessionController(
      repository: FakeRepository(),
      recallGateway: gateway,
    );
    await c.initialize();
    await c.addSubject('Demo', Priority.medium);
    await c.startPlan(tasks: [task]);
    final pending = c.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.requested, isNotNull);
    final oldId = c.recallRun!.id;
    await c.finishRecall();
    await c.startPlan(tasks: [task]);
    final newId = c.recallRun!.id;
    final sample = await SampleRecallGateway().submit(
      RecallMaterial.sample,
      'fixture',
      [],
    );
    gateway.result.complete(
      RecallJob(gateway.requested!, 'ready', quiz: sample.quiz),
    );
    await pending;
    expect(c.recallRun!.id, newId);
    expect(newId, isNot(oldId));
    expect(c.recallRun!.entries.single.quiz, isNull);
    c.dispose();
  });

  test(
    'answer save failure preserves memory and retries to durable storage',
    () async {
      var time = DateTime.utc(2026);
      final repo = FakeRepository();
      final c = SessionController(
        repository: repo,
        clock: () => time,
        recallGateway: SampleRecallGateway(),
      );
      await c.initialize();
      await c.addSubject('Demo', Priority.medium);
      await c.startPlan(tasks: [task]);
      await c.readyToFocus();
      time = time.add(const Duration(seconds: 10));
      await c.refresh();
      await c.endSession();
      await c.startRecall();
      repo.failSave = true;
      await c.setRecallAnswer('q0/a', 'retrieval');
      expect(c.error, isNotNull);
      expect(c.recallRun!.answers['q0/a'], 'retrieval');
      expect(repo.workspace.recall.current!.answers, isEmpty);
      repo.failSave = false;
      await c.retry();
      final restored = SessionController(repository: repo, clock: () => time);
      await restored.initialize();
      expect(restored.recallRun!.answers['q0/a'], 'retrieval');
      expect(restored.recallRun!.stage, 'answering');
      restored.dispose();
      c.dispose();
    },
  );

  test('cancelled preparation never creates an eligible empty quiz', () async {
    final c = SessionController(
      repository: FakeRepository(),
      recallGateway: DeferredRecall(),
    );
    await c.initialize();
    await c.addSubject('Demo', Priority.medium);
    await c.startPlan(tasks: [task]);
    await c.endSession();
    expect(c.active, isNull);
    expect(c.recallRun, isNull);
    expect(c.blocks, isEmpty);
    c.dispose();
  });
}
