import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'models.dart';

const studyTracks = ['Aria', 'Variation 13', 'Variation 15'];

class ProtectionStatus {
  const ProtectionStatus({
    this.supported = false,
    this.dndAccess = false,
    this.alarmAccess = false,
    this.blockingAccess = false,
    this.dndActive = false,
    this.blockingActive = false,
    this.message,
  });
  final bool supported,
      dndAccess,
      alarmAccess,
      blockingAccess,
      dndActive,
      blockingActive;
  final String? message;
}

/// No-op implementation keeps non-Android builds and unit tests usable.
class FocusServices extends ChangeNotifier {
  ProtectionStatus status = const ProtectionStatus();
  bool playing = false;
  int currentTrack = 0;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool seekable = false;
  bool previewing = false;
  String? audioError;
  Future<void> reconcile(ActiveSession? session, AppSettings settings) async {}
  Future<void> refreshStatus() async {}
  Future<void> openPermission(String permission) async {}
  Future<List<Map<String, String>>> installedApps() async => [];
  Future<void> music(String action, {int? track, double? volume}) async {}
  Future<void> setVolume(double volume) async {}
  Future<void> seek(Duration position, {required int track}) async {}
}

class AndroidFocusServices extends FocusServices with WidgetsBindingObserver {
  AndroidFocusServices() {
    WidgetsBinding.instance.addObserver(this);
  }
  Completer<void>? _permissionReturn;
  bool _disposed = false;
  int _volumeRevision = 0;
  double _latestVolume = 0.5;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _permissionReturn?.isCompleted == false) {
      _permissionReturn!.complete();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (_permissionReturn?.isCompleted == false) _permissionReturn!.complete();
    super.dispose();
  }

  static const _channel = MethodChannel('dev.nudge/focus');

  Future<dynamic> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<dynamic>(method, args);
    } on MissingPluginException {
      status = const ProtectionStatus(
        message: 'Device controls are available on Android.',
      );
    } on PlatformException catch (error) {
      status = ProtectionStatus(
        supported: true,
        message:
            error.message ?? 'Device controls are temporarily unavailable.',
      );
    }
    return null;
  }

  @override
  Future<void> refreshStatus() async {
    if (_disposed) return;
    final value = await _call('status');
    if (_disposed) return;
    if (value is Map) {
      status = ProtectionStatus(
        supported: true,
        dndAccess: value['dndAccess'] == true,
        alarmAccess: value['alarmAccess'] == true,
        blockingAccess: value['blockingAccess'] == true,
        dndActive: value['dndActive'] == true,
        blockingActive: value['blockingActive'] == true,
        message: value['message'] as String?,
      );
      playing = value['playing'] == true;
      currentTrack = (value['track'] as int? ?? 0).clamp(
        0,
        studyTracks.length - 1,
      );
      audioError = value['audioError'] as String?;
      duration = Duration(
        milliseconds: (value['duration'] as int? ?? 0).clamp(0, 1 << 53),
      );
      position = Duration(
        milliseconds: (value['position'] as int? ?? 0).clamp(
          0,
          duration.inMilliseconds,
        ),
      );
      seekable = value['seekable'] == true && duration > Duration.zero;
      previewing = value['previewing'] == true;
    }
    notifyListeners();
  }

  @override
  Future<void> reconcile(ActiveSession? session, AppSettings settings) async {
    final volumeRevision = _volumeRevision;
    final deadline = session?.protectionDeadline.millisecondsSinceEpoch ?? 0;
    final timerPaused = session?.isPaused ?? false;
    await _call('protect', {
      'until': deadline,
      'timerPaused': timerPaused,
      'generation': session?.blockId ?? '',
      'intense': settings.intenseFocus,
      'apps': settings.blockedApps,
    });
    // A drag can arrive while the protection call is in flight.
    final volume = volumeRevision == _volumeRevision
        ? settings.volume
        : _latestVolume;
    final run = session == null
        ? null
        : session.planned
        ? session.tasks.first.id
        : session.blockId;
    if (settings.track < 0 || (run == null && !previewing)) {
      await _call('music', {'action': 'stop'});
    } else if (run == null) {
      await _call('music', {
        'action': 'syncPreview',
        'track': settings.track,
        'volume': volume,
      });
    } else {
      // Restoring an app does not restart music that the user paused natively.
      await _call('music', {
        'action': 'startRun',
        'run': run,
        'track': settings.track,
        'volume': volume,
        'until': deadline,
        'timerPaused': timerPaused,
      });
    }
    await refreshStatus();
  }

  @override
  Future<void> openPermission(String permission) async {
    _permissionReturn = Completer<void>();
    final opened = await _call('permission', {'kind': permission});
    if (opened == true) await _permissionReturn!.future;
    _permissionReturn = null;
    await refreshStatus();
  }

  @override
  Future<List<Map<String, String>>> installedApps() async {
    final apps = await _call('apps');
    if (apps is! List) return [];
    return apps.map((item) => Map<String, String>.from(item as Map)).toList();
  }

  @override
  Future<void> setVolume(double volume) async {
    // A drag should affect the player immediately without reloading playback/status.
    _volumeRevision++;
    _latestVolume = volume.clamp(0.0, 1.0);
    await _call('music', {'action': 'volume', 'volume': _latestVolume});
  }

  @override
  Future<void> seek(Duration position, {required int track}) async {
    await _call('music', {
      'action': 'seek',
      'track': track,
      'position': position.inMilliseconds,
    });
    await refreshStatus();
  }

  @override
  Future<void> music(String action, {int? track, double? volume}) async {
    final result = await _call('music', {
      'action': action,
      'track': track,
      'volume': volume,
    });
    if (result == null && status.message != null) audioError = status.message;
    await refreshStatus();
  }
}
