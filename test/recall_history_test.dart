import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/models.dart';
import 'package:nudge/recall_models.dart';
import 'package:nudge/session_controller.dart';

import 'fake_repository.dart';

void main() {
  testWidgets(
    'recall expansion and history scroll restore separate state after tab changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final quiz = RecallQuiz.fromJson(
        jsonDecode(File('assets/recall/sample_quiz.json').readAsStringSync())
            as Map<String, dynamic>,
      );
      final run = RecallRun(
        id: 'saved',
        stage: 'submitted',
        quiz: quiz,
        tasks: [
          FocusTask(
            id: 'saved-task',
            subjectId: 1,
            title: 'Saved recall',
          ).toJson(),
        ],
        answers: const {'q0/a': 'retrieval'},
      );
      final repo = FakeRepository()
        ..subjects = [
          for (var i = 1; i <= 20; i++)
            Subject(id: i, name: 'Subject $i', priority: Priority.medium),
        ]
        ..workspace = WorkspaceState(recall: RecallState(runs: [run]));
      final c = SessionController(repository: repo);
      await c.initialize();
      addTearDown(c.dispose);
      await tester.pumpWidget(NudgeApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      final list = find.byKey(const PageStorageKey('history'));
      for (var i = 0; i < 8; i++) {
        await tester.drag(list, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      final attempt = find.text('Saved recall');
      await tester.ensureVisible(attempt);
      await tester.pumpAndSettle();
      await tester.tap(attempt);
      await tester.pumpAndSettle();
      expect(find.text('Retrieval practice'), findsOneWidget);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('10% · Simulated demo'), findsOneWidget);
      expect(find.text('Retrieval practice'), findsOneWidget);
    },
  );
}
