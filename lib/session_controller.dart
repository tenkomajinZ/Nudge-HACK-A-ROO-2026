import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'study_repository.dart';
import 'focus_services.dart';
import 'recall_models.dart';
import 'recall_gateway.dart';

part 'recall_controller.dart';

typedef Clock = DateTime Function();

class SessionController extends ChangeNotifier {
  SessionController({
    required this.repository,
    Clock? clock,
    FocusServices? services,
    RecallGateway? recallGateway,
  }) : clock = clock ?? DateTime.now,
       services = services ?? FocusServices() {
    this.recallGateway = recallGateway ?? SampleRecallGateway();
  }
  static const focusDuration = Duration(minutes: 10);
  static const breakDuration = Duration(minutes: 5);
  final StudyRepository repository;
  final Clock clock;
  final FocusServices services;
  late final RecallGateway recallGateway;
  bool _recallNetworkBusy = false;
  bool _recallGradingBusy = false;
  int _recallGradeSerial = 0;
  bool get recallGradingBusy => _recallGradingBusy;
  String? recallGradingMessage;
  List<Subject> _subjects = [];
  List<StudyBlock> _blocks = [];
  ActiveSession? _active;
  WorkspaceState _workspace = const WorkspaceState();
  List<StudyBlock> _pendingBlocks = [];
  bool _pendingSave = false, _disposed = false;
  Completer<void>? _idleWaiter;
  bool ready = false, busy = false;
  String? error;
  String? notice;
  List<Subject> get subjects =>
      List.unmodifiable(_subjects.where((s) => !s.isDeleted));
  List<Subject> get historySubjects => List.unmodifiable(_subjects);
  List<StudyBlock> get blocks => List.unmodifiable(_blocks);
  List<FocusTask> get queue => List.unmodifiable(_workspace.queue);
  AppSettings get settings => _workspace.settings;
  ActiveSession? get active => _active;
  bool get canAct => ready && !busy && error == null;
  DateTime get now => clock().toUtc();
  Duration get remaining {
    final session = _active;
    if (session == null) return Duration.zero;
    if (session.pausedPreparationMillis case final millis?) {
      return Duration(milliseconds: millis);
    }
    final value = session.endsAt.difference(session.pausedAt ?? now);
    return value.isNegative ? Duration.zero : value;
  }

  int totalSeconds(int subjectId) => _blocks
      .where((b) => b.subjectId == subjectId)
      .fold(0, (sum, b) => sum + b.focusSeconds);
  Subject subject(int id) => _subjects.firstWhere((s) => s.id == id);
  void _requireAvailableSubject(int id) {
    if (subject(id).isDeleted) {
      throw StateError('This task was deleted. Choose an available task.');
    }
  }

  void _notify() {
    if (!busy) {
      _idleWaiter?.complete();
      _idleWaiter = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    _notify();
    try {
      final saved = await repository.load();
      _subjects = saved.subjects;
      _sortSubjects();
      _blocks = saved.blocks;
      _active = saved.active;
      _workspace = saved.workspace;
      ready = true;
      final session = _active;
      if (session != null &&
          session.phase == SessionPhase.preparing &&
          session.pausedPreparationMillis != null) {
        _active = _resumePreparationAt(session, remaining, now);
        await _save();
      }
      if (_advanceExpired()) {
        await _save();
      } else {
        await _reconcile();
      }
    } catch (_) {
      error =
          'Could not open local data. Retry to load your tasks and session.';
    } finally {
      busy = false;
      _notify();
    }
  }

  void _sortSubjects() => _subjects.sort((a, b) {
    final priority = b.priority.index.compareTo(a.priority.index);
    return priority != 0 ? priority : a.id.compareTo(b.id);
  });

  Future<void> addSubject(String name, Priority priority) async {
    if (!canAct) return;
    if (name.trim().isEmpty) throw ArgumentError('Enter a task name.');
    busy = true;
    _notify();
    try {
      final created = await repository.addSubject(name.trim(), priority);
      _subjects = [..._subjects, created];
      _sortSubjects();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> editSubject(int id, String name, Priority priority) async {
    if (!canAct) return;
    _requireAvailableSubject(id);
    if (name.trim().isEmpty) throw ArgumentError('Enter a task name.');
    busy = true;
    _notify();
    try {
      final updated = Subject(id: id, name: name.trim(), priority: priority);
      await repository.updateSubject(updated);
      _subjects = _subjects.map((s) => s.id == id ? updated : s).toList();
      _sortSubjects();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> deleteSubject(int id) async {
    if (!canAct) {
      throw StateError(
        'Finish saving your changes, then retry deleting the task.',
      );
    }
    if (_active != null || recallRun != null) {
      throw StateError(
        'Finish your study or recall run before deleting a task.',
      );
    }
    _requireAvailableSubject(id);
    final updated = WorkspaceState(
      settings: settings,
      recall: _workspace.recall,
      queue: queue.where((task) => task.subjectId != id).toList(),
    );
    busy = true;
    _notify();
    try {
      await repository.deleteSubject(id, workspace: updated);
      _subjects = _subjects
          .map(
            (s) => s.id == id
                ? Subject(
                    id: s.id,
                    name: s.name,
                    priority: s.priority,
                    isDeleted: true,
                  )
                : s,
          )
          .toList();
      _workspace = updated;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> updateSettings(AppSettings value) => _change(() {
    _workspace = WorkspaceState(
      recall: _workspace.recall,
      settings: value,
      queue: queue,
    );
    return true;
  });

  Future<void> setAiDocumentConsent(bool granted) async {
    if (!canAct) {
      throw StateError(
        'Finish saving your changes, then retry AI document permission.',
      );
    }
    await updateSettings(settings.copyWith(aiDocumentConsent: granted));
    if (error != null) throw StateError(error!);
  }

  void previewVolume(double value) {
    if (!ready || error != null || _disposed) return;
    final volume = value.clamp(0.0, 1.0);
    _workspace = WorkspaceState(
      recall: _workspace.recall,
      settings: settings.copyWith(volume: volume),
      queue: queue,
    );
    unawaited(services.setVolume(volume));
    _notify();
  }

  Future<void> persistVolume() async {
    // Do not drop the final value if a timer transition or earlier save is running.
    while (busy && !_disposed) {
      await (_idleWaiter ??= Completer<void>()).future;
    }
    if (_disposed) return;
    await _change(() => true, reconcileDevices: false);
  }

  Future<void> saveTask(FocusTask task) => _change(() {
    task.config.validate();
    _requireAvailableSubject(task.subjectId);
    if (task.title.trim().isEmpty) throw ArgumentError('Enter a task name.');
    final items = [...queue];
    final index = items.indexWhere((item) => item.id == task.id);
    if (index < 0) {
      items.add(task);
    } else {
      items[index] = task;
    }
    _workspace = WorkspaceState(
      recall: _workspace.recall,
      settings: settings,
      queue: List.unmodifiable(items),
    );
    return true;
  });
  Future<void> removeTask(String id) => _change(() {
    _workspace = WorkspaceState(
      recall: _workspace.recall,
      settings: settings,
      queue: queue.where((task) => task.id != id).toList(),
    );
    return true;
  });
  Future<void> moveTask(int index, int delta) => _change(() {
    final items = [...queue];
    final target = index + delta;
    if (index < 0 ||
        target < 0 ||
        index >= items.length ||
        target >= items.length) {
      return false;
    }
    final task = items.removeAt(index);
    items.insert(target, task);
    _workspace = WorkspaceState(
      recall: _workspace.recall,
      settings: settings,
      queue: items,
    );
    return true;
  });

  String _blockId(int subjectId) {
    final base = '$subjectId-${now.microsecondsSinceEpoch}';
    var id = base, suffix = 0;
    while (_blocks.any((block) => block.id == id) || _active?.blockId == id) {
      id = '$base-${++suffix}';
    }
    return id;
  }

  ActiveSession _focus(
    int subjectId, {
    ActiveSession? previous,
    DateTime? start,
    int? taskIndex,
    int? repeatIndex,
    int? completed,
  }) {
    final begin = start ?? now;
    final index = taskIndex ?? previous?.taskIndex ?? 0;
    final task = previous?.planned == true ? previous!.tasks[index] : null;
    return ActiveSession(
      blockId: _blockId(subjectId),
      subjectId: subjectId,
      phase: SessionPhase.focus,
      startedAt: begin,
      endsAt: begin.add(Duration(minutes: task?.config.focusMinutes ?? 10)),
      tasks: previous?.tasks ?? const [],
      taskIndex: index,
      repeatIndex: repeatIndex ?? previous?.repeatIndex ?? 0,
      completedInRun: completed ?? previous?.completedInRun ?? 0,
      autoRepeat: previous?.autoRepeat ?? false,
    );
  }

  // Compatibility entry point for restored Phase 1 cycles.
  Future<void> startFocus(int subjectId) => _change(() {
    if (_active != null || recallRun != null) return false;
    _requireAvailableSubject(subjectId);
    notice = null;
    _active = _focus(subjectId);
    return true;
  });

  Future<void> startPlan({List<FocusTask>? tasks}) => _change(() {
    if (_active != null || recallRun != null) return false;
    final snapshot = List<FocusTask>.unmodifiable(tasks ?? queue);
    if (snapshot.isEmpty) return false;
    for (final task in snapshot) {
      _requireAvailableSubject(task.subjectId);
      task.config.validate();
    }
    notice = null;
    _beginRecallRun(snapshot);
    _active = ActiveSession(
      blockId: _blockId(snapshot.first.subjectId),
      subjectId: snapshot.first.subjectId,
      phase: SessionPhase.preparing,
      startedAt: now,
      endsAt: now.add(const Duration(seconds: 30)),
      tasks: snapshot,
      autoRepeat: true,
    );
    return true;
  });

  Future<void> pauseSession({SessionPhase? expectedPhase}) => _change(() {
    final at = now;
    final advanced = _advanceExpired(at);
    final session = _active;
    if (session == null ||
        (expectedPhase != null && session.phase != expectedPhase) ||
        session.isPaused ||
        session.pausedPreparationMillis != null ||
        !at.isBefore(session.endsAt)) {
      return advanced;
    }
    _active = session.withTiming(pausedAt: at);
    _notify();
    return true;
  });

  Future<void> resumeSession() => _change(() {
    final session = _active;
    final pausedAt = session?.pausedAt;
    if (session == null || pausedAt == null) return false;
    final pause = now.difference(pausedAt);
    _active = session.withTiming(
      endsAt: session.endsAt.add(pause),
      pausedMillis: session.pausedMillis + pause.inMilliseconds,
    );
    return true;
  });

  Future<void> pausePreparation() => _change(() {
    final session = _active;
    if (session == null ||
        session.phase != SessionPhase.preparing ||
        session.isPaused ||
        session.pausedPreparationMillis != null) {
      return false;
    }
    _active = session.withTiming(
      pausedPreparationMillis: remaining.inMilliseconds,
    );
    return true;
  });
  Future<void> resumePreparation() => _change(() {
    final session = _active;
    if (session == null || session.pausedPreparationMillis == null) {
      return false;
    }
    final duration = Duration(milliseconds: session.pausedPreparationMillis!);
    _active = _resumePreparationAt(session, duration, now);
    return true;
  });

  ActiveSession _resumePreparationAt(
    ActiveSession session,
    Duration remaining,
    DateTime at,
  ) => session.withTiming(
    startedAt: at.subtract(session.phaseDuration - remaining),
    endsAt: at.add(remaining),
    pausedMillis: 0,
  );

  Future<void> readyToFocus() => _change(() {
    final session = _active;
    if (session == null ||
        session.phase != SessionPhase.preparing ||
        session.pausedPreparationMillis != null) {
      return false;
    }
    _active = _focus(session.subjectId, previous: session);
    return true;
  });

  bool _advanceExpired([DateTime? at]) {
    final cutoff = at ?? now;
    var changed = false;
    while (true) {
      final session = _active;
      if (session == null ||
          session.isPaused ||
          session.pausedPreparationMillis != null ||
          cutoff.isBefore(session.endsAt)) {
        break;
      }
      switch (session.phase) {
        case SessionPhase.preparing:
          _active = _focus(
            session.subjectId,
            previous: session,
            start: session.endsAt,
          );
        case SessionPhase.focus:
          _completeFocus(session);
        case SessionPhase.rest:
          if (!session.repeatsAutomatically) {
            if (recallRun?.stage == 'studying' && _hasRecallFocus) {
              _setRecallRun(recallRun!.copyWith(stage: 'choice'));
              return true;
            }
            return changed;
          }
          _startNextFocus(session, session.endsAt);
      }
      // An automatic break only advances to another repetition of this task.
      changed = true;
    }
    return changed;
  }

  void _completeFocus(ActiveSession session) {
    _recordFocus(session, session.endsAt, completed: true);
    if (session.planned &&
        session.repeatIndex + 1 == session.task!.config.repeats) {
      _workspace = WorkspaceState(
        recall: _workspace.recall,
        settings: settings,
        queue: queue.where((task) => task.id != session.task!.id).toList(),
      );
    }
    if (!session.hasNext) {
      _active = null;
      notice = 'Study session complete. Well done for showing up!';
      if (_hasRecallFocus) _setRecallRun(recallRun!.copyWith(stage: 'choice'));
      return;
    }
    _active = ActiveSession(
      blockId: session.blockId,
      subjectId: session.subjectId,
      phase: SessionPhase.rest,
      startedAt: session.endsAt,
      endsAt: session.endsAt.add(session.breakDuration),
      tasks: session.tasks,
      taskIndex: session.taskIndex,
      repeatIndex: session.repeatIndex,
      completedInRun: session.completedInRun,
      autoRepeat: session.autoRepeat,
    );
  }

  void _recordFocus(
    ActiveSession session,
    DateTime end, {
    required bool completed,
  }) {
    if (_blocks.any((block) => block.id == session.blockId)) return;
    final elapsed =
        end.difference(session.startedAt) -
        Duration(milliseconds: session.pausedMillis);
    final seconds = elapsed.inSeconds.clamp(0, session.focusDuration.inSeconds);
    if (seconds == 0 && !completed) return;
    final block = StudyBlock(
      id: session.blockId,
      subjectId: session.subjectId,
      startedAt: session.startedAt,
      endedAt: end,
      focusSeconds: seconds,
      completed: completed,
      runId: recallRun?.id,
      taskId: session.task?.id,
    );
    _blocks = [block, ..._blocks];
    _pendingBlocks.add(block);
  }

  Future<void> refresh() async {
    if (!canAct) return;
    await _change(_advanceExpired);
    await pollRecall();
  }

  Future<void> returnToStudy() => _change(() {
    final advanced = _advanceExpired();
    final session = _active;
    if (session == null ||
        session.phase != SessionPhase.rest ||
        session.isPaused) {
      return advanced;
    }
    _startNextFocus(session, now);
    return true;
  });

  void _startNextFocus(ActiveSession session, DateTime start) {
    if (recallRun != null) {
      _setRecallRun(recallRun!.copyWith(stage: 'studying'));
    }
    var index = session.taskIndex, repeat = session.repeatIndex + 1;
    if (session.planned && repeat >= session.task!.config.repeats) {
      index++;
      repeat = 0;
    }
    final subjectId = session.planned
        ? session.tasks[index].subjectId
        : session.subjectId;
    _active = _focus(
      subjectId,
      previous: session,
      start: start,
      taskIndex: index,
      repeatIndex: repeat,
      completed: session.completedInRun + 1,
    );
  }

  Future<void> endSession() => _change(() {
    if (_active == null) return false;
    _advanceExpired();
    final session = _active;
    if (session?.phase == SessionPhase.focus) {
      _recordFocus(session!, session.pausedAt ?? now, completed: false);
    }
    // Keep only the remaining repetitions when a multi-block task is ended early.
    if (session != null && session.planned) {
      final done =
          session.repeatIndex + (session.phase == SessionPhase.rest ? 1 : 0);
      final task = session.task!;
      if (done > 0 && done < task.config.repeats) {
        _workspace = WorkspaceState(
          recall: _workspace.recall,
          settings: settings,
          queue: queue
              .map(
                (item) => item.id == task.id
                    ? FocusTask(
                        id: item.id,
                        subjectId: item.subjectId,
                        title: item.title,
                        material: item.material,
                        config: TimerConfig(
                          focusMinutes: item.config.focusMinutes,
                          breakMinutes: item.config.breakMinutes,
                          repeats: task.config.repeats - done,
                          pomodoro: item.config.pomodoro,
                        ),
                      )
                    : item,
              )
              .toList(),
        );
      }
    }
    _active = null;
    notice = 'Study time saved. Come back when you are ready.';
    if (_hasRecallFocus) {
      _setRecallRun(recallRun!.copyWith(stage: 'choice'));
    } else if (recallRun != null) {
      _workspace = WorkspaceState(
        settings: settings,
        queue: queue,
        recall: RecallState(runs: _workspace.recall.runs),
      );
    }
    return true;
  });

  Future<void> _change(
    bool Function() change, {
    bool reconcileDevices = true,
  }) async {
    if (!canAct) return;
    busy = true;
    try {
      if (change()) await _save(reconcileDevices: reconcileDevices);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _reconcile() async {
    try {
      await services.reconcile(_active, settings);
    } catch (_) {
      services.status = const ProtectionStatus(
        message:
            'Device controls are unavailable. Your timer and study data are safe.',
      );
    }
  }

  Future<void> _save({bool reconcileDevices = true}) async {
    _pendingSave = true;
    try {
      await repository.commit(
        _active,
        List.of(_pendingBlocks),
        workspace: _workspace,
      );
      _pendingBlocks = [];
      _pendingSave = false;
      error = null;
      if (reconcileDevices) await _reconcile();
    } catch (_) {
      error = 'Changes are only in memory. Keep NUDGE open and retry saving.';
      // Ending a run must release controls even when disk persistence fails.
      if (_active == null && reconcileDevices) await _reconcile();
    }
  }

  Future<void> retry() async {
    if (busy || _disposed) return;
    if (!_pendingSave) {
      await initialize();
      return;
    }
    busy = true;
    _notify();
    await _save();
    busy = false;
    _notify();
    if (error == null) await refresh();
  }

  Future<void> reconcileDevices() async {
    if (ready && error == null) {
      await refresh();
      await _reconcile();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _idleWaiter?.complete();
    _idleWaiter = null;
    services.dispose();
    super.dispose();
  }
}
