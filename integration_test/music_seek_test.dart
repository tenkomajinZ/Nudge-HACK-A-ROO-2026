import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.nudge/focus');

  testWidgets('offline previews seek forward, backward and while paused', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    Future<void> command(String action, {int? track, int? position}) =>
        channel.invokeMethod<void>('music', {
          'action': action,
          'track': track,
          'position': position,
          'volume': 0.0,
        });
    Future<Map<dynamic, dynamic>> status() async =>
        (await channel.invokeMethod<Map<dynamic, dynamic>>('status'))!;
    Future<Map<dynamic, dynamic>> waitFor(
      bool Function(Map<dynamic, dynamic>) matches,
    ) async {
      var value = await status();
      for (var attempt = 0; attempt < 80 && !matches(value); attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        value = await status();
      }
      expect(value['audioError'], isNull);
      expect(matches(value), true, reason: 'Playback state: $value');
      return value;
    }

    try {
      for (var track = 0; track < 3; track++) {
        await command('preview', track: track);
        await waitFor(
          (s) =>
              s['track'] == track &&
              s['playing'] == true &&
              s['seekable'] == true &&
              (s['duration'] as int) > 90000,
        );
        for (final target in [90000, 15000, 60000]) {
          await command('seek', track: track, position: target);
          await waitFor(
            (s) =>
                s['playing'] == true &&
                ((s['position'] as int) - target).abs() < 2500,
          );
        }
        await command('toggle');
        await waitFor((s) => s['playing'] == false);
        await command('seek', track: track, position: 30000);
        await waitFor(
          (s) =>
              s['playing'] == false &&
              ((s['position'] as int) - 30000).abs() < 1000,
        );
        // A preference save must preserve the paused position.
        await command('syncPreview', track: track);
        final paused = await status();
        expect(paused['playing'], false);
        expect(paused['position'] as int, closeTo(30000, 1000));
        await command('seek', track: (track + 1) % 3, position: 0);
        expect((await status())['position'] as int, closeTo(30000, 1000));
        await command('toggle');
        await waitFor(
          (s) => s['playing'] == true && (s['position'] as int) >= 30000,
        );
      }
    } finally {
      await command('stop');
    }
    expect((await status())['playing'], false);
  });
}
