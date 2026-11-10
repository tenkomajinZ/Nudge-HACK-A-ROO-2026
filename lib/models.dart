// Shared timer, settings, and persistence models.
import 'recall_models.dart';

enum Priority { low, medium, high }

// Original ordinals are retained for version-one databases.
enum SessionPhase { focus, rest, preparing }

enum Appearance { light, dark, system }

class TimerConfig {
  const TimerConfig({
    this.focusMinutes = 10,
    this.breakMinutes = 5,
    this.repeats = 1,
    this.pomodoro = false,
  });
  final int focusMinutes;
  final int breakMinutes;
  final int repeats;
  final bool pomodoro;
  void validate() {
    if (focusMinutes < 1 ||
        focusMinutes > 180 ||
        breakMinutes < 0 ||
        breakMinutes > 60 ||
        repeats < 1 ||
        repeats > 12) {
      throw ArgumentError('Choose focus 1–180, break 0–60, and 1–12 blocks.');
    }
  }

  Map<String, Object?> toJson() => {
    'focus': focusMinutes,
    'break': breakMinutes,
    'repeats': repeats,
    'pomodoro': pomodoro,
  };
  factory TimerConfig.fromJson(Map<String, dynamic> json) => TimerConfig(
    focusMinutes: json['focus'] as int,
    breakMinutes: json['break'] as int,
    repeats: json['repeats'] as int,
    pomodoro: json['pomodoro'] as bool? ?? false,
  );
}

class FocusTask {
  const FocusTask({
    required this.id,
    required this.subjectId,
    required this.title,
    this.config = const TimerConfig(),
    this.material,
  });
  final String id;
  final int subjectId;
  final String title;
  final TimerConfig config;
  final RecallMaterial? material;
  Map<String, Object?> toJson() => {
    'id': id,
    'subject': subjectId,
    'title': title,
    'config': config.toJson(),
    'material': material?.toJson(),
  };
  factory FocusTask.fromJson(Map<String, dynamic> json) => FocusTask(
    id: json['id'] as String,
    subjectId: json['subject'] as int,
    title: json['title'] as String,
    config: TimerConfig.fromJson(json['config'] as Map<String, dynamic>),
    material: json['material'] == null
        ? null
        : RecallMaterial.fromJson(
            Map<String, dynamic>.from(json['material'] as Map),
          ),
  );
}

class AppSettings {
  const AppSettings({
    this.appearance = Appearance.light,
    this.intenseFocus = false,
    this.blockedApps = const [],
    this.track = -1,
    this.volume = 0.5,
    this.aiDocumentConsent = false,
  });
  final Appearance appearance;
  final bool intenseFocus;
  final List<String> blockedApps;
  // -1 means silence. Playback is always an explicit choice.
  final int track;
  final double volume;
  final bool aiDocumentConsent;
  AppSettings copyWith({
    Appearance? appearance,
    bool? intenseFocus,
    List<String>? blockedApps,
    int? track,
    double? volume,
    bool? aiDocumentConsent,
  }) => AppSettings(
    appearance: appearance ?? this.appearance,
    intenseFocus: intenseFocus ?? this.intenseFocus,
    blockedApps: List.unmodifiable(blockedApps ?? this.blockedApps),
    track: track ?? this.track,
    volume: volume ?? this.volume,
    aiDocumentConsent: aiDocumentConsent ?? this.aiDocumentConsent,
  );
  Map<String, Object?> toJson() => {
    'appearance': appearance.name,
    'intense': intenseFocus,
    'apps': blockedApps,
    'track': track,
    'volume': volume,
    'aiDocumentConsent': aiDocumentConsent,
  };
  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    appearance: Appearance.values.byName(
      json['appearance'] as String? ?? 'light',
    ),
    intenseFocus: json['intense'] as bool? ?? false,
    blockedApps: (json['apps'] as List? ?? []).cast<String>(),
    track: json['track'] as int? ?? -1,
    volume: (json['volume'] as num? ?? 0.5).toDouble(),
    aiDocumentConsent: json['aiDocumentConsent'] == true,
  );
}

class WorkspaceState {
  const WorkspaceState({
    this.settings = const AppSettings(),
    this.queue = const [],
    this.recall = const RecallState(),
  });
  final AppSettings settings;
  final List<FocusTask> queue;
  final RecallState recall;
  Map<String, Object?> toJson() => {
    'settings': settings.toJson(),
    'queue': queue.map((task) => task.toJson()).toList(),
    'recall': recall.toJson(),
  };
  factory WorkspaceState.fromJson(Map<String, dynamic> json) => WorkspaceState(
    settings: AppSettings.fromJson(json['settings'] as Map<String, dynamic>),
    queue: (json['queue'] as List)
        .map((task) => FocusTask.fromJson(task as Map<String, dynamic>))
        .toList(),
    recall: json['recall'] == null
        ? const RecallState()
        : RecallState.fromJson(
            Map<String, dynamic>.from(json['recall'] as Map),
          ),
  );
}

class Subject {
  const Subject({
    required this.id,
    required this.name,
    required this.priority,
    this.isDeleted = false,
  });
  final int id;
  final String name;
  final Priority priority;
  final bool isDeleted;
}

class StudyBlock {
  const StudyBlock({
    required this.id,
    required this.subjectId,
    required this.startedAt,
    required this.endedAt,
    required this.focusSeconds,
    required this.completed,
    this.runId,
    this.taskId,
  });
  final String id;
  final int subjectId;
  final DateTime startedAt;
  final DateTime endedAt;
  final int focusSeconds;
  final bool completed;
  final String? runId, taskId;
}

class ActiveSession {
  const ActiveSession({
    required this.blockId,
    required this.subjectId,
    required this.phase,
    required this.startedAt,
    required this.endsAt,
    this.tasks = const [],
    this.taskIndex = 0,
    this.repeatIndex = 0,
    this.completedInRun = 0,
    this.pausedPreparationMillis,
    this.autoRepeat = false,
    this.pausedAt,
    this.pausedMillis = 0,
  });
  final String blockId;
  final int subjectId;
  final SessionPhase phase;
  final DateTime startedAt;
  final DateTime endsAt;
  final List<FocusTask> tasks;
  final int taskIndex;
  final int repeatIndex;
  final int completedInRun;
  final int? pausedPreparationMillis;
  final bool autoRepeat;
  final DateTime? pausedAt;
  final int pausedMillis;
  bool get isPaused => pausedAt != null;
  Duration get phaseDuration =>
      endsAt.difference(startedAt) - Duration(milliseconds: pausedMillis);
  bool get planned => tasks.isNotEmpty;
  FocusTask? get task => planned ? tasks[taskIndex] : null;
  Duration get focusDuration =>
      Duration(minutes: task?.config.focusMinutes ?? 10);
  bool get hasNext =>
      !planned ||
      repeatIndex + 1 < task!.config.repeats ||
      taskIndex + 1 < tasks.length;
  bool get repeatsAutomatically =>
      autoRepeat && planned && repeatIndex + 1 < task!.config.repeats;

  Duration _breakAfter(int completedBefore) => Duration(
    minutes: task?.config.pomodoro == true && (completedBefore + 1) % 4 == 0
        ? 15
        : task?.config.breakMinutes ?? 5,
  );
  Duration get breakDuration => _breakAfter(completedInRun);

  DateTime get protectionDeadline {
    var deadline = endsAt;
    if (phase == SessionPhase.preparing) deadline = deadline.add(focusDuration);
    if (phase != SessionPhase.rest && hasNext) {
      deadline = deadline.add(breakDuration);
    }
    if (repeatsAutomatically) {
      final repeats = task!.config.repeats;
      for (var i = repeatIndex + 1; i < repeats; i++) {
        deadline = deadline.add(focusDuration);
        if (i + 1 < repeats || taskIndex + 1 < tasks.length) {
          deadline = deadline.add(
            _breakAfter(completedInRun + i - repeatIndex),
          );
        }
      }
    }
    return deadline;
  }

  // Replace timing state while retaining the current phase and task progress.
  ActiveSession withTiming({
    DateTime? startedAt,
    DateTime? endsAt,
    int? pausedPreparationMillis,
    DateTime? pausedAt,
    int? pausedMillis,
  }) => ActiveSession(
    blockId: blockId,
    subjectId: subjectId,
    phase: phase,
    startedAt: startedAt ?? this.startedAt,
    endsAt: endsAt ?? this.endsAt,
    tasks: tasks,
    taskIndex: taskIndex,
    repeatIndex: repeatIndex,
    completedInRun: completedInRun,
    autoRepeat: autoRepeat,
    pausedPreparationMillis: pausedPreparationMillis,
    pausedAt: pausedAt,
    pausedMillis: pausedMillis ?? this.pausedMillis,
  );
  Map<String, Object?> toJson() => {
    'blockId': blockId,
    'subject': subjectId,
    'phase': phase.index,
    'start': startedAt.millisecondsSinceEpoch,
    'end': endsAt.millisecondsSinceEpoch,
    'tasks': tasks.map((task) => task.toJson()).toList(),
    'taskIndex': taskIndex,
    'repeatIndex': repeatIndex,
    'completed': completedInRun,
    'paused': pausedPreparationMillis,
    'autoRepeat': autoRepeat,
    'pausedAt': pausedAt?.millisecondsSinceEpoch,
    'pausedMillis': pausedMillis,
  };
  factory ActiveSession.fromJson(Map<String, dynamic> json) => ActiveSession(
    blockId: json['blockId'] as String,
    subjectId: json['subject'] as int,
    phase: SessionPhase.values[json['phase'] as int],
    startedAt: DateTime.fromMillisecondsSinceEpoch(
      json['start'] as int,
      isUtc: true,
    ),
    endsAt: DateTime.fromMillisecondsSinceEpoch(
      json['end'] as int,
      isUtc: true,
    ),
    tasks: List.unmodifiable(
      (json['tasks'] as List).map(
        (task) => FocusTask.fromJson(task as Map<String, dynamic>),
      ),
    ),
    taskIndex: json['taskIndex'] as int,
    repeatIndex: json['repeatIndex'] as int,
    completedInRun: json['completed'] as int,
    pausedPreparationMillis: json['paused'] as int?,
    autoRepeat: json['autoRepeat'] == true,
    pausedAt: json['pausedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            json['pausedAt'] as int,
            isUtc: true,
          ),
    pausedMillis: json['pausedMillis'] as int? ?? 0,
  );
}

class StoredState {
  const StoredState({
    required this.subjects,
    required this.blocks,
    required this.active,
    this.workspace = const WorkspaceState(),
  });
  final List<Subject> subjects;
  final List<StudyBlock> blocks;
  final ActiveSession? active;
  final WorkspaceState workspace;
}

String formatCountdown(Duration remaining) {
  final seconds = (remaining.inMilliseconds / 1000).ceil().clamp(0, 86400);
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

String formatMinutes(int seconds) => (seconds / 60).toStringAsFixed(1);
