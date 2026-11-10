import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nudge/focus_services.dart';
import 'package:nudge/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.nudge/focus');
  final calls = <MethodCall>[];
  late AndroidFocusServices services;
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'status') {
            return <String, Object?>{
              'dndAccess': false,
              'alarmAccess': false,
              'blockingAccess': false,
              'dndActive': false,
              'blockingActive': false,
              'playing': false,
              'track': 0,
              'position': 45000,
              'duration': 180000,
              'seekable': true,
            };
          }
          return true;
        });
    services = AndroidFocusServices();
  });
  tearDown(() {
    services.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  ActiveSession session() => ActiveSession(
    blockId: 'block',
    subjectId: 1,
    phase: SessionPhase.focus,
    startedAt: DateTime.utc(2026),
    endsAt: DateTime.utc(2026).add(const Duration(minutes: 25)),
    tasks: const [FocusTask(id: 'run-task', subjectId: 1, title: 'Math')],
  );

  test(
    'late playback status is ignored after the music service is disposed',
    () async {
      final response = Completer<Map<String, Object?>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) => response.future);
      final closingServices = AndroidFocusServices();
      final refresh = closingServices.refreshStatus();
      closingServices.dispose();
      response.complete({'playing': true, 'track': 1});
      await refresh;
      expect(closingServices.playing, false);
    },
  );

  test(
    'a drag during device synchronization retains the newer volume',
    () async {
      final protection = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'protect') return protection.future;
            if (call.method == 'status') return <String, Object?>{};
            return true;
          });
      final syncing = services.reconcile(
        session(),
        const AppSettings(track: 0, volume: 0.2),
      );
      await services.setVolume(0.9);
      protection.complete(true);
      await syncing;
      final start = calls.firstWhere(
        (call) =>
            call.method == 'music' &&
            (call.arguments as Map)['action'] == 'startRun',
      );
      expect((start.arguments as Map)['volume'], 0.9);
    },
  );

  test(
    'seeking sends a position and track without restarting playback',
    () async {
      await services.refreshStatus();
      expect(services.position, const Duration(seconds: 45));
      expect(services.duration, const Duration(minutes: 3));
      expect(services.seekable, true);
      calls.clear();
      await services.seek(const Duration(seconds: 90), track: 0);
      expect(calls.first.method, 'music');
      expect(calls.first.arguments, {
        'action': 'seek',
        'track': 0,
        'position': 90000,
      });
      expect(calls.where((call) => call.method == 'music').length, 1);
    },
  );

  test(
    'cold restoration with Silence always stops a surviving native player',
    () async {
      await services.reconcile(session(), const AppSettings());
      expect(
        calls
            .where((call) => call.method == 'music')
            .map((call) => (call.arguments as Map)['action']),
        ['stop'],
      );
      expect(services.status.dndAccess, false);
    },
  );
  test(
    'music synchronization uses a stable run key and releases everything on end',
    () async {
      const settings = AppSettings(
        track: 1,
        volume: 0.25,
        intenseFocus: true,
        blockedApps: ['example.app'],
      );
      await services.reconcile(session(), settings);
      await services.reconcile(session(), settings);
      final starts = calls.where((call) => call.method == 'music').toList();
      expect(starts.length, 2);
      for (final call in starts) {
        expect((call.arguments as Map)['action'], 'startRun');
        expect((call.arguments as Map)['run'], 'run-task');
        expect((call.arguments as Map)['track'], 1);
      }
      calls.clear();
      await services.reconcile(null, settings);
      expect((calls.first.arguments as Map)['until'], 0);
      expect(
        (calls.firstWhere((call) => call.method == 'music').arguments
            as Map)['action'],
        'stop',
      );
    },
  );
  test(
    'manual pause holds protection and music until the new deadline',
    () async {
      final running = session();
      final paused = running.withTiming(
        pausedAt: running.startedAt.add(const Duration(minutes: 1)),
      );
      const settings = AppSettings(track: 0, intenseFocus: true);
      await services.reconcile(paused, settings);
      expect((calls.first.arguments as Map)['timerPaused'], true);
      expect((calls[1].arguments as Map)['timerPaused'], true);
      expect((calls[1].arguments as Map)['action'], 'startRun');
      calls.clear();
      final resumed = paused.withTiming(
        endsAt: running.endsAt.add(const Duration(minutes: 4)),
        pausedMillis: 240000,
      );
      await services.reconcile(resumed, settings);
      expect((calls.first.arguments as Map)['timerPaused'], false);
      expect((calls[1].arguments as Map)['timerPaused'], false);
      expect(
        (calls.first.arguments as Map)['until'],
        resumed.endsAt.millisecondsSinceEpoch,
      );
      expect((calls[1].arguments as Map)['run'], 'run-task');
    },
  );

  test(
    'pausing preparation for the picker retains a bounded protection lease',
    () async {
      final start = DateTime.utc(2026);
      final paused = ActiveSession(
        blockId: 'preparing',
        subjectId: 1,
        phase: SessionPhase.preparing,
        startedAt: start,
        endsAt: start.add(const Duration(seconds: 30)),
        pausedPreparationMillis: 20000,
      );
      await services.reconcile(paused, const AppSettings());
      expect(
        (calls.first.arguments as Map)['until'],
        paused.protectionDeadline.millisecondsSinceEpoch,
      );
      expect((calls.first.arguments as Map)['until'], isNot(0));
    },
  );
}
