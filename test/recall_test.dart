import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/recall_gateway.dart';
import 'package:nudge/session_controller.dart';

import 'fake_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('score bands and multipart weighting use unrounded scores', () {
    expect(recallTier(100), 'perfect');
    expect(recallTier(99.9), 'veryGood');
    expect(recallTier(70), 'veryGood');
    expect(recallTier(69.99), 'almost');
    expect(recallTier(50), 'almost');
    expect(recallTier(49.99), 'review');
    final quiz = RecallQuiz.fromJson({
      'simulated': true,
      'questions': [
        for (var i = 0; i < 10; i++)
          {
            'id': 'q$i',
            'concept': 'concept$i',
            'prompt': 'Explain $i',
            'source': 'Demo notes, page 1',
            'evidence': 'Fact $i',
            'explanation': 'Explanation',
            'parts': [
              {
                'id': 'a',
                'prompt': 'One',
                'kind': 'fill',
                'options': <String, String>{},
                'correct': '',
                'accepted': ['Hello world'],
              },
              {
                'id': 'b',
                'prompt': 'Two',
                'kind': 'choice',
                'options': {'a': 'yes', 'b': 'no'},
                'correct': 'a',
                'accepted': <String>[],
              },
            ],
          },
      ],
    });
    expect(quiz.score({'q0/a': '  HELLO   world  '}), 5);
    expect(quiz.score({}), 0);
    final roundTrip = RecallQuiz.fromJson(quiz.toJson());
    expect(roundTrip.questions.length, 10);
    expect(() => RecallQuiz.fromJson({'questions': []}), throwsFormatException);
  });

  test(
    'recall survives final completion, answers and review; unstarted tasks excluded',
    () async {
      var time = DateTime.utc(2026, 10, 26);
      final repository = FakeRepository();
      final controller = SessionController(
        repository: repository,
        clock: () => time,
        recallGateway: SampleRecallGateway(),
      );
      await controller.initialize();
      await controller.addSubject('Biology', Priority.medium);
      const task = FocusTask(
        id: 't1',
        subjectId: 1,
        title: 'Retrieval practice',
        material: RecallMaterial.sample,
      );
      const unstarted = FocusTask(
        id: 't2',
        subjectId: 1,
        title: 'Unstarted',
        material: RecallMaterial.sample,
      );
      await controller.saveTask(task);
      await controller.saveTask(unstarted);
      await controller.startPlan();
      await controller.readyToFocus();
      time = time.add(const Duration(seconds: 15));
      await controller.refresh();
      await controller.endSession();
      expect(controller.recallRun!.stage, 'choice');
      expect(controller.blocks.single.runId, controller.recallRun!.id);
      expect(controller.blocks.single.taskId, 't1');
      expect(controller.active, isNull);
      expect(controller.queue.any((t) => t.id == 't2'), isTrue);
      expect(
        controller.recallRun!.entries.firstWhere((e) => e.taskId == 't2').quiz,
        isNull,
      );
      expect(
        controller.recallReady,
        isTrue,
        reason: controller.recallRun!.entries.map((e) => e.error).join(', '),
      );
      await controller.startRecall();
      await controller.setRecallAnswer('q0/a', 'retrieval');
      final second = SessionController(
        repository: repository,
        clock: () => time,
        recallGateway: SampleRecallGateway(),
      );
      await second.initialize();
      expect(second.recallRun!.answers['q0/a'], 'retrieval');
      expect(second.recallRun!.stage, 'answering');
      for (final question in second.recallRun!.quiz!.questions) {
        for (final part in question.parts) {
          if (!second.recallRun!.answers.containsKey(
            '${question.id}/${part.id}',
          )) {
            await second.setRecallAnswer(
              '${question.id}/${part.id}',
              part.kind == 'choice' ? part.options.keys.first : 'wrong',
            );
          }
        }
        await second.checkRecallAnswer(question.id);
        await second.nextRecallQuestion(question.id);
      }
      await second.submitRecall(runId: second.recallRun!.id);
      expect(second.recallRun!.stage, 'submitted');
      final oldId = second.recallRun!.id;
      await second.studyAgain(5);
      expect(second.recallRun!.id, isNot(oldId));
      expect(second.active!.task!.config.focusMinutes, 5);
      expect(second.active!.task!.material, isNotNull);
      expect(
        second.recallHistory.any(
          (run) => run.id == oldId && run.stage == 'submitted',
        ),
        isTrue,
      );
      second.dispose();
      controller.dispose();
    },
  );

  test(
    'automatic repeats keep studying until the final focus completes',
    () async {
      var time = DateTime.utc(2026);
      final controller = SessionController(
        repository: FakeRepository(),
        clock: () => time,
        recallGateway: SampleRecallGateway(),
      );
      await controller.initialize();
      await controller.addSubject('Math', Priority.low);
      await controller.startPlan(
        tasks: const [
          FocusTask(
            id: 'r',
            subjectId: 1,
            title: 'Recall',
            config: TimerConfig(focusMinutes: 1, breakMinutes: 1, repeats: 2),
            material: RecallMaterial.sample,
          ),
        ],
      );
      await controller.readyToFocus();
      time = time.add(const Duration(minutes: 1));
      await controller.refresh();
      expect(controller.active!.phase, SessionPhase.rest);
      time = time.add(const Duration(minutes: 1));
      await controller.refresh();
      expect(controller.active!.phase, SessionPhase.focus);
      expect(controller.active!.repeatIndex, 1);
      expect(controller.recallRun!.stage, 'studying');
      time = time.add(const Duration(minutes: 1));
      await controller.refresh();
      expect(controller.active, isNull);
      expect(controller.recallRun!.stage, 'choice');
      await controller.finishRecall();
      await controller.startPlan(
        tasks: const [
          FocusTask(
            id: 'plain',
            subjectId: 1,
            title: 'Plain',
            config: TimerConfig(focusMinutes: 1),
          ),
        ],
      );
      await controller.readyToFocus();
      time = time.add(const Duration(minutes: 1));
      await controller.refresh();
      expect(controller.recallRun, isNull);
      expect(controller.active, isNull);
      controller.dispose();
    },
  );
  test('multi-material sampling keeps ten distinct mixed questions', () async {
    var time = DateTime.utc(2026);
    final c = SessionController(
      repository: FakeRepository(),
      clock: () => time,
      recallGateway: SampleRecallGateway(),
    );
    await c.initialize();
    await c.addSubject('Demo', Priority.medium);
    await c.startPlan(
      tasks: const [
        FocusTask(
          id: 'first',
          subjectId: 1,
          title: 'First',
          config: TimerConfig(focusMinutes: 1, breakMinutes: 0),
          material: RecallMaterial.sample,
        ),
        FocusTask(
          id: 'second',
          subjectId: 1,
          title: 'Second',
          config: TimerConfig(focusMinutes: 1),
          material: RecallMaterial.sample,
        ),
      ],
    );
    await c.readyToFocus();
    time = time.add(const Duration(minutes: 1));
    await c.refresh();
    await c.returnToStudy();
    time = time.add(const Duration(minutes: 1));
    await c.refresh();
    expect(c.recallReady, isTrue);
    await c.startRecall();
    final quiz = c.recallRun!.quiz!;
    expect(
      quiz.questions.map((q) => normalizeRecall(q.wording)).toSet().length,
      10,
    );
    expect(
      quiz.questions.expand((q) => q.parts.map((p) => p.kind)).toSet(),
      containsAll(['choice', 'fill']),
    );
    expect(quiz.questions.any((q) => q.parts.length > 1), isTrue);
    expect(quiz.questions.any((q) => q.id.startsWith('first-')), isTrue);
    expect(quiz.questions.any((q) => q.id.startsWith('second-')), isTrue);
    c.dispose();
  });
  test(
    'fractional multipart credit reaches the exact seventy-percent band',
    () {
      final q = RecallQuiz.fromJson({
        'simulated': true,
        'questions': [
          for (var i = 0; i < 10; i++)
            {
              'id': 'q$i',
              'concept': '$i',
              'prompt': 'Question $i',
              'source': 'Page 1',
              'evidence': 'Fact',
              'explanation': 'Explanation',
              'parts': [
                for (var p = 0; p < 3; p++)
                  {
                    'id': '$p',
                    'prompt': 'Part $p',
                    'kind': p == 0 ? 'choice' : 'fill',
                    'options': p == 0
                        ? {'a': 'yes', 'b': 'no'}
                        : <String, String>{},
                    'correct': p == 0 ? 'a' : '',
                    'accepted': p == 0 ? <String>[] : ['yes'],
                  },
              ],
            },
        ],
      });
      final answers = {
        for (var i = 0; i < 9; i++)
          for (var p = 0; p < (i < 6 ? 3 : 1); p++)
            'q$i/$p': p == 0 ? 'a' : 'yes',
      };
      final score = q.score(answers);

      expect(score, 70);
      expect(recallTier(score), 'veryGood');
    },
  );
}
