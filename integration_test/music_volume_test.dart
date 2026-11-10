import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nudge/focus_services.dart';
import 'package:nudge/focus_widgets.dart';
import 'package:nudge/session_controller.dart';
import 'package:nudge/sqlite_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.nudge/focus');

  testWidgets(
    'volume gestures update Android live and persist without disturbing playback',
    (tester) async {
      final databaseName =
          'volume-test-${DateTime.now().microsecondsSinceEpoch}.db';
      final repository = SqliteRepository(databaseName: databaseName);
      final audio = AndroidFocusServices();
      final controller = SessionController(
        repository: repository,
        services: audio,
      );
      await controller.initialize();
      await controller.updateSettings(controller.settings.copyWith(track: 0));
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (_, _) => MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MusicPanel(controller: controller),
              ),
            ),
          ),
        ),
      );
      Future<Map<dynamic, dynamic>> status() async =>
          (await channel.invokeMethod<Map<dynamic, dynamic>>('status'))!;
      Future<void> waitFor(bool Function(Map<dynamic, dynamic>) matches) async {
        var value = await status();
        for (var attempt = 0; attempt < 80 && !matches(value); attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          value = await status();
        }
        expect(value['audioError'], isNull);
        expect(matches(value), true, reason: 'Playback state: $value');
      }

      Future<double> dragTo(double fraction, {required bool playing}) async {
        final slider = find.byKey(const ValueKey('music-volume'));
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        final rect = tester.getRect(slider);
        final gesture = await tester.startGesture(rect.center);
        await gesture.moveTo(
          Offset(rect.left + rect.width * fraction, rect.center.dy),
        );
        await tester.pump();
        final selected = tester.widget<Slider>(slider).value;
        // Read the real ExoPlayer volume while the finger is still down.
        await waitFor(
          (s) => ((s['volume'] as num).toDouble() - selected).abs() < 0.001,
        );
        final during = await status();
        expect(during['playing'], playing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          (await repository.load()).workspace.settings.volume,
          closeTo(selected, 0.001),
        );
        return selected;
      }

      try {
        await channel.invokeMethod<void>('music', {
          'action': 'preview',
          'track': 0,
          'volume': 0.5,
        });
        await audio.setVolume(0.2);
        await waitFor(
          (s) =>
              s['playing'] == true &&
              s['seekable'] == true &&
              ((s['volume'] as num).toDouble() - 0.2).abs() < 0.001,
        );
        await audio.refreshStatus();
        await tester.pumpAndSettle();
        await audio.seek(const Duration(seconds: 45), track: 0);
        await waitFor(
          (s) => s['playing'] == true && (s['position'] as int) >= 44000,
        );
        await dragTo(0, playing: true);
        expect((await status())['volume'] as num, 0);
        await dragTo(1, playing: true);
        final selected = await dragTo(0.35, playing: true);
        expect((await status())['position'] as int, greaterThan(44000));
        await audio.music('next');
        await waitFor((s) => s['track'] == 1 && s['playing'] == true);
        expect((await status())['volume'] as num, closeTo(selected, 0.001));
        await audio.seek(const Duration(seconds: 30), track: 1);
        await waitFor(
          (s) => s['playing'] == true && (s['position'] as int) >= 29000,
        );
        await audio.music('toggle');
        await waitFor((s) => s['playing'] == false);
        final paused = await dragTo(0.65, playing: false);
        expect((await status())['position'] as int, closeTo(30000, 2000));
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await repository.close();
        final reopened = SqliteRepository(databaseName: databaseName);
        expect(
          (await reopened.load()).workspace.settings.volume,
          closeTo(paused, 0.001),
        );
        await reopened.close();
      } finally {
        await channel.invokeMethod<void>('music', {'action': 'stop'});
      }
    },
  );
}
