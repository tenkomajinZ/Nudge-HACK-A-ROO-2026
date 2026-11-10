import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/models.dart';
import 'package:nudge/session_controller.dart';

import 'fake_repository.dart';

void main() {
  testWidgets('Home starts the selected task and clears a deleted choice', (
    tester,
  ) async {
    final controller = SessionController(repository: FakeRepository());
    addTearDown(controller.dispose);
    await controller.initialize();
    for (final name in ['Q&A', 'Bio', 'Math']) {
      await controller.addSubject(name, Priority.medium);
    }
    await controller.saveTask(
      const FocusTask(id: 'saved', subjectId: 3, title: 'Saved review'),
    );
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();

    final start = find.widgetWithText(FilledButton, 'Choose study method');
    final hero = find.byKey(const ValueKey('focus-hero'));
    Finder cardTitle(String name) =>
        find.descendant(of: hero, matching: find.text(name));
    Finder row(String name) => find.widgetWithText(ListTile, name);
    expect(cardTitle('Study setup'), findsNothing);
    expect(find.text('One small start.'), findsNothing);
    expect(cardTitle('Choose a task to begin'), findsOneWidget);
    expect(tester.widget<FilledButton>(start).onPressed, isNull);

    await tester.tap(row('Bio'));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(row('Bio')).selected, isTrue);
    expect(cardTitle('Bio'), findsOneWidget);
    expect(cardTitle('Choose a study method'), findsNothing);
    final card = tester.widget<Container>(hero);
    final decoration = card.decoration! as BoxDecoration;
    final colors = Theme.of(tester.element(hero)).colorScheme;
    expect(decoration.color, colors.primaryContainer);
    expect(decoration.gradient, isNull);
    expect(decoration.border, Border.all(color: colors.outlineVariant));
    expect(card.padding, const EdgeInsets.all(16));
    expect(tester.getSize(start).height, greaterThanOrEqualTo(48));

    await tester.tap(find.byTooltip('Task options for Q&A'));
    await tester.pumpAndSettle();
    expect(find.text('Edit task'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(cardTitle('Bio'), findsOneWidget);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(find.text('How do you want to study Bio?'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(cardTitle('Bio'), findsOneWidget);

    await tester.tap(row('Q&A'));
    await tester.pumpAndSettle();
    expect(cardTitle('Q&A'), findsOneWidget);
    expect(tester.widget<ListTile>(row('Bio')).selected, isFalse);
    await tester.tap(find.byTooltip('Task options for Q&A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(cardTitle('Your next session'), findsOneWidget);
    await tester.tap(find.byTooltip('Task options for Math'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(row('Bio')).selected, isTrue);
    expect(cardTitle('Bio'), findsOneWidget);
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final recall in [false, true]) {
    testWidgets(
      '${recall ? 'Active Recall' : 'Focus'} starts after adding a task on an empty home',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = recall
            ? const Size(668, 375)
            : const Size(375, 760);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        var time = DateTime.utc(2026);
        final controller = SessionController(
          repository: FakeRepository(),
          clock: () => time,
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(NudgeApp(controller: controller));
        await tester.pumpAndSettle();

        expect(find.text('One small start.'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Empty'),
          80,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Tasks'), findsOneWidget);
        expect(find.text('Empty'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Study'), findsNothing);
        await tester.ensureVisible(find.text('Add task'));
        await tester.tap(find.text('Add task'));
        await tester.pumpAndSettle();
        expect(find.text('Task name'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), ' Biology ');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect(find.text('Tasks'), findsOneWidget);
        expect(find.text('Empty'), findsNothing);
        expect(find.text('One small start.'), findsNothing);
        expect(controller.subjects.single.name, 'Biology');
        final tile = find.widgetWithText(ListTile, 'Biology');
        expect(tester.widget<ListTile>(tile).selected, isTrue);
        expect(find.text('Study'), findsNothing);
        final study = find.text('Choose study method');
        await tester.scrollUntilVisible(
          study,
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(study);
        await tester.pumpAndSettle();
        expect(find.text('How do you want to study Biology?'), findsOneWidget);
        await tester.tap(find.text(recall ? 'Active Recall' : 'Focus'));
        await tester.pumpAndSettle();

        if (recall) {
          expect(find.text('Choose PDF or photo'), findsNothing);
          expect(find.text('Take a picture'), findsNothing);
          final next = find.text('Use sample notes');
          await tester.ensureVisible(next);
          await tester.tap(next);
          await tester.pumpAndSettle();
        }
        expect(find.text('Choose your rhythm'), findsOneWidget);
        expect(find.text('Biology'), findsOneWidget);
        if (recall) expect(find.text('Demonstration notes'), findsOneWidget);
        final pomodoro = find.widgetWithText(ChoiceChip, 'Pomodoro');
        await tester.ensureVisible(pomodoro);
        await tester.tap(pomodoro);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('Add a session'));
        await tester.tap(find.byTooltip('Add a session'));
        await tester.pumpAndSettle();
        expect(find.text('Music'), findsOneWidget);
        expect(find.text('Intense Focus'), findsNothing);
        expect(find.text('Make room for focus'), findsOneWidget);
        final start = find.text('Start preparation');
        await tester.ensureVisible(start);
        await tester.tap(start);
        await tester.pumpAndSettle();

        expect(controller.subjects.single.name, 'Biology');
        expect(controller.active!.phase, SessionPhase.preparing);
        expect(controller.active!.task!.config.repeats, 2);
        expect(controller.active!.task!.config.breakMinutes, 5);
        expect(
          controller.active!.task!.material?.name,
          recall ? 'Demonstration notes' : null,
        );
        expect(controller.recallRun != null, recall);
        expect(find.text('0:30'), findsOneWidget);
        expect(find.text('Music'), findsNothing);
        expect(find.text('Intense Focus'), findsNothing);
        expect(find.text('Biology'), findsNothing);
        expect(find.byTooltip('Pause timer'), findsOneWidget);
        expect(find.text('Skip preparation'), findsOneWidget);

        time = time.add(const Duration(seconds: 30));
        await controller.refresh();
        await tester.pumpAndSettle();
        expect(controller.active!.phase, SessionPhase.focus);
        expect(find.text('25:00'), findsOneWidget);
        expect(find.text('Session 1 of 2'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
