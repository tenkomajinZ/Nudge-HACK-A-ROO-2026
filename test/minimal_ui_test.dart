import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/main.dart';
import 'package:nudge/focus_services.dart';
import 'package:nudge/focus_widgets.dart';
import 'package:nudge/models.dart';
import 'package:nudge/session_controller.dart';
import 'fake_repository.dart';

class TrackServices extends FocusServices {
  void advance() {
    currentTrack = 1;
    duration = const Duration(minutes: 3);
    playing = true;
    notifyListeners();
  }
}

void main() {
  for (final compact in [false, true]) {
    testWidgets(
      'current song stays visible when player is expanded, compact $compact',
      (tester) async {
        final audio = TrackServices();
        final controller = SessionController(
          repository: FakeRepository(),
          services: audio,
        );
        await controller.initialize();
        await controller.updateSettings(controller.settings.copyWith(track: 0));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MusicPanel(controller: controller, compact: compact),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (compact) {
          await tester.tap(find.text('Music'));
          await tester.pumpAndSettle();
        }
        audio.advance();
        await tester.pumpAndSettle();
        expect(controller.settings.track, 0);
        expect(find.text('Variation 13 · Playing'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }

  testWidgets('home keeps one phrase while focus stays minimal', (
    tester,
  ) async {
    final controller = SessionController(
      repository: FakeRepository(),
      clock: () => DateTime.utc(2026),
    );
    await controller.initialize();
    await tester.pumpWidget(NudgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Nudge'), findsOneWidget);
    expect(find.text('Add task'), findsOneWidget);
    expect(find.text('One small start.'), findsOneWidget);
    expect(find.text('Your pace. Your priorities.'), findsNothing);
    expect(find.text('A little space for what matters.'), findsNothing);
    expect(
      find.text('Add your first subject to start studying.'),
      findsNothing,
    );
    await controller.addSubject('Calculus', Priority.high);
    await tester.pumpAndSettle();
    expect(find.text('Choose study method'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Calculus'), findsOneWidget);
    expect(find.textContaining('min studied'), findsNothing);
    await controller.startFocus(1);
    await tester.pumpAndSettle();
    expect(find.text('Focus'), findsOneWidget);
    expect(find.text('One small start.'), findsNothing);
    expect(find.text('Your pace. Your priorities.'), findsNothing);
    expect(find.text('Finish'), findsOneWidget);
    expect(find.text('Just this task, just this moment.'), findsNothing);
    expect(find.textContaining('minutes logged'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
