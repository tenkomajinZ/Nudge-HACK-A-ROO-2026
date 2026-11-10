import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'session_controller.dart';
import 'sqlite_repository.dart';
import 'focus_services.dart';
import 'focus_widgets.dart';
import 'nudge_theme.dart';
import 'recall_widgets.dart';
import 'study_setup.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final services = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? AndroidFocusServices()
      : FocusServices();
  runApp(
    NudgeApp(
      controller: SessionController(
        repository: SqliteRepository(),
        services: services,
      ),
    ),
  );
}

class NudgeApp extends StatelessWidget {
  const NudgeApp({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MaterialApp(
      title: 'Nudge · Hackaroo Demo',
      debugShowCheckedModeBanner: false,
      theme: NudgeTheme.build(Brightness.light),
      darkTheme: NudgeTheme.build(Brightness.dark),
      themeMode: switch (controller.settings.appearance) {
        Appearance.light => ThemeMode.light,
        Appearance.dark => ThemeMode.dark,
        Appearance.system => ThemeMode.system,
      },
      home: StudyHome(controller: controller),
    ),
  );
}

class StudyHome extends StatefulWidget {
  const StudyHome({super.key, required this.controller});
  final SessionController controller;
  @override
  State<StudyHome> createState() => _StudyHomeState();
}

class _StudyHomeState extends State<StudyHome> with WidgetsBindingObserver {
  Timer? _ticker;
  int _tab = 0;
  bool _showHome = false;
  int? _selectedTaskId;

  bool get _recalling =>
      controller.recallRun != null &&
      [
        'choice',
        'answering',
        'submitted',
      ].contains(controller.recallRun!.stage);
  bool get _hasRun => controller.active != null || controller.recallRun != null;
  bool get _canEdit => controller.canAct && !_hasRun;
  void _home() => setState(() {
    _showHome = true;
    _tab = 0;
  });
  void _resume() => setState(() {
    _showHome = false;
    _tab = 0;
  });
  SessionController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          controller.ready ? controller.refresh() : controller.initialize(),
        );
      }
    });
    _startTicker();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(controller.refresh());
      unawaited(controller.services.refreshStatus());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(controller.reconcileDevices());
      _startTicker();
    } else {
      _ticker?.cancel();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _editStudyTask([Subject? existing]) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => StudyTaskDialog(controller: controller, existing: existing),
  );

  Future<void> _deleteStudyTask(Subject subject) async {
    if (!_canEdit) return;
    var deleting = false;
    String? failure;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, update) => PopScope(
          canPop: !deleting,
          child: AlertDialog(
            title: Text('Delete ${subject.name}?'),
            scrollable: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Remove this task and its linked plan items? Your study history, quiz results, and saved documents will stay.',
                ),
                if (failure != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    failure!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: deleting ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: deleting
                    ? null
                    : () async {
                        update(() {
                          deleting = true;
                          failure = null;
                        });
                        try {
                          await controller.deleteSubject(subject.id);
                          if (mounted && _selectedTaskId == subject.id) {
                            setState(() => _selectedTaskId = null);
                          }
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (_) {
                          if (dialogContext.mounted) {
                            update(() {
                              deleting = false;
                              failure = 'Could not delete the task. Try again.';
                            });
                          }
                        }
                      },
                child: Text(deleting ? 'Deleting…' : 'Delete'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editPlanItem(FocusTask existing) async {
    if (!_canEdit || controller.subjects.isEmpty) return;
    final task = await Navigator.of(context).push<FocusTask>(
      MaterialPageRoute<FocusTask>(
        fullscreenDialog: true,
        builder: (_) => PlanItemDialog(
          controller: controller,
          subjects: controller.subjects,
          existing: existing,
        ),
      ),
    );
    if (!mounted || task == null) return;
    await controller.saveTask(task);
  }

  Future<void> _study(Subject task) async {
    if (!_canEdit || ModalRoute.of(context)?.isCurrent != true) return;
    final started = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => StudyMethodPage(
          taskName: task.name,
          controller: controller,
          onStart: (config, material) async {
            if (!_canEdit) return false;
            await controller.startPlan(
              tasks: [
                FocusTask(
                  id: 'task-${DateTime.now().microsecondsSinceEpoch}',
                  subjectId: task.id,
                  title: task.name,
                  config: config,
                  material: material,
                ),
              ],
            );
            return controller.active != null;
          },
        ),
      ),
    );
    if (mounted && started == true) _resume();
  }

  Future<void> _preparePlan() async {
    if (!_canEdit || controller.queue.isEmpty) return;
    final tasks = controller.queue;
    final started = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RhythmPage(
          taskName: tasks.first.title,
          controller: controller,
          savedPlan: true,
          onStart: (_, _) async {
            if (!_canEdit) return false;
            await controller.startPlan(tasks: tasks);
            return controller.active != null;
          },
        ),
      ),
    );
    if (mounted && started == true) _resume();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final immersive =
          _tab == 0 && !_showHome && (controller.active != null || _recalling);
      final dark = theme.brightness == Brightness.dark;
      final focusBackdrop = immersive && !_recalling;
      return PopScope(
        canPop: !immersive,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _home();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            gradient: dark
                ? (focusBackdrop ? NudgeTheme.darkFocus : NudgeTheme.darkCanvas)
                : null,
          ),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              automaticallyImplyLeading: false,
              leading: immersive
                  ? IconButton(
                      tooltip: 'Home',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: _home,
                    )
                  : null,
              title: immersive
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/branding/nudge-mark.png',
                          width: 28,
                          height: 28,
                          color: theme.colorScheme.primary,
                          colorBlendMode: BlendMode.srcIn,
                          excludeFromSemantics: true,
                        ),
                        const SizedBox(width: 8),
                        const Text('Nudge'),
                      ],
                    ),
              actions: immersive
                  ? null
                  : [
                      IconButton(
                        tooltip: 'Settings',
                        icon: const Icon(Icons.tune_rounded),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                SettingsScreen(controller: controller),
                          ),
                        ),
                      ),
                    ],
            ),
            body: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth:
                        immersive &&
                            _recalling &&
                            controller.recallRun?.stage == 'answering'
                        ? 1120
                        : 680,
                  ),
                  child: Column(
                    children: [
                      if (controller.error != null) _errorBanner(),
                      if (controller.busy) const LinearProgressIndicator(),
                      Expanded(
                        child: !controller.ready
                            ? Center(
                                child: controller.error == null
                                    ? const CircularProgressIndicator()
                                    : const Text(
                                        'Local data is not loaded yet.',
                                      ),
                              )
                            : _tab == 1
                            ? _history()
                            : immersive
                            ? (_recalling
                                  ? RecallScreen(controller: controller)
                                  : _session())
                            : _studyTasks(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            bottomNavigationBar: immersive
                ? null
                : NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: (value) => setState(() {
                      _tab = value;
                      _showHome = true;
                    }),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home_outlined),
                        selectedIcon: Icon(Icons.home_rounded),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.history_rounded),
                        label: 'History',
                      ),
                    ],
                  ),
          ),
        ),
      );
    },
  );

  Widget _errorBanner() => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.error!,
              semanticsLabel: 'Storage error. ${controller.error}',
            ),
          ),
          TextButton(
            onPressed: controller.busy ? null : controller.retry,
            child: const Text('Retry'),
          ),
        ],
      ),
    ),
  );

  String get _phaseName => switch (controller.active!.phase) {
    SessionPhase.preparing => 'Get ready',
    SessionPhase.focus => 'Focus',
    SessionPhase.rest =>
      controller.remaining == Duration.zero ? 'Break over' : 'Break',
  };

  Widget _focusCard(Subject? selected, {required bool empty}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final idle = !_hasRun;
    final dark = theme.brightness == Brightness.dark;
    final ink = idle
        ? colors.onPrimaryContainer
        : dark
        ? const Color(0xfffaf7ff)
        : const Color(0xff2b1d48);
    final session = controller.active;
    final task = session?.task;
    final action = _recalling
        ? 'Continue recall'
        : session != null
        ? 'Return to focus'
        : empty
        ? 'Add task'
        : 'Choose study method';
    final title = _recalling
        ? 'Active Recall'
        : task?.title ??
              (session != null
                  ? controller.subject(session.subjectId).name
                  : selected?.name ?? 'Your next session');
    final detail = _recalling
        ? 'Continue where you left off'
        : task != null
        ? controller.subject(task.subjectId).name
        : session != null
        ? 'Your current session'
        : empty
        ? 'Choose what matters today'
        : selected == null
        ? 'Choose a task to begin'
        : null;
    return Container(
      key: const ValueKey('focus-hero'),
      decoration: BoxDecoration(
        color: idle ? colors.primaryContainer : null,
        gradient: idle ? null : NudgeTheme.heroGradient(theme.brightness),
        border: idle ? Border.all(color: colors.outlineVariant) : null,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: idle
          ? const EdgeInsets.all(16)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: ink),
        child: IconTheme(
          data: IconThemeData(color: ink),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_recalling || session != null)
                          Text(
                            _recalling ? 'Ready to recall' : _phaseName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        Text(
                          title,
                          style: idle
                              ? theme.textTheme.headlineSmall?.copyWith(
                                  color: ink,
                                )
                              : const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  height: 1.25,
                                ),
                        ),
                        if (detail != null)
                          Text(detail, style: const TextStyle(fontSize: 14)),
                      ],
                    ),
                  ),
                  if (!_hasRun && controller.queue.isNotEmpty)
                    IconButton(
                      tooltip: 'Saved study plan',
                      color: ink,
                      icon: const Icon(Icons.more_vert),
                      onPressed: _canEdit ? _managePlan : null,
                    ),
                  if (session?.phase == SessionPhase.preparing)
                    PopupMenuButton<bool>(
                      tooltip: 'Preparation options',
                      enabled: controller.canAct,
                      onSelected: (_) => controller.endSession(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: true,
                          child: Text('Cancel preparation'),
                        ),
                      ],
                    ),
                ],
              ),
              SizedBox(height: idle ? 12 : 8),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!_recalling && session != null)
                    Text(
                      formatCountdown(controller.remaining),
                      style: const TextStyle(
                        fontSize: 36,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    onPressed: !controller.canAct
                        ? null
                        : _hasRun
                        ? _resume
                        : empty
                        ? () => _editStudyTask()
                        : selected != null
                        ? () => _study(selected)
                        : null,
                    icon: Icon(
                      idle && empty ? Icons.add : Icons.arrow_forward_rounded,
                    ),
                    iconAlignment: idle && !empty
                        ? IconAlignment.end
                        : IconAlignment.start,
                    label: Text(action),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _studyTasks() {
    final tasks = controller.subjects;
    final selected = _hasRun
        ? null
        : tasks.length == 1
        ? tasks.single
        : tasks.where((task) => task.id == _selectedTaskId).firstOrNull;
    final colors = Theme.of(context).colorScheme;
    return ListView(
      key: const PageStorageKey('tasks'),
      padding: NudgeTheme.pagePadding,
      children: [
        if (tasks.isEmpty && !_hasRun) ...[
          Text(
            'One small start.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 24),
        ],
        _focusCard(selected, empty: tasks.isEmpty),
        if (controller.notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              label: controller.notice,
              liveRegion: true,
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      controller.notice!.startsWith('Study session complete')
                          ? 'Session complete'
                          : 'Saved',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
        Text('Tasks', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (tasks.isEmpty)
          Text('Empty', style: Theme.of(context).textTheme.bodySmall)
        else ...[
          for (final subject in tasks) ...[
            ListTile(
              key: ValueKey(subject.id),
              title: Text(subject.name),
              selected: selected?.id == subject.id,
              selectedTileColor: colors.primaryContainer,
              selectedColor: colors.onPrimaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: _canEdit && tasks.length > 1
                  ? () => setState(() => _selectedTaskId = subject.id)
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected?.id == subject.id)
                    Icon(Icons.check_rounded, color: colors.onPrimaryContainer),
                  PopupMenuButton<String>(
                    tooltip: 'Task options for ${subject.name}',
                    enabled: _canEdit,
                    onSelected: (action) {
                      if (action == 'edit') _editStudyTask(subject);
                      if (action == 'delete') _deleteStudyTask(subject);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit task')),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete task'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _canEdit ? () => _editStudyTask() : null,
              icon: const Icon(Icons.add),
              label: const Text('Add task'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _taskMenu(int index) {
    final task = controller.queue[index];
    return PopupMenuButton<String>(
      tooltip: 'Plan item options for ${task.title}',
      enabled: _canEdit,
      onSelected: (action) {
        if (action == 'up') controller.moveTask(index, -1);
        if (action == 'down') controller.moveTask(index, 1);
        if (action == 'edit') _editPlanItem(task);
        if (action == 'remove') controller.removeTask(task.id);
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'up',
          enabled: index > 0,
          child: const Text('Move plan item up'),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: index + 1 < controller.queue.length,
          child: const Text('Move plan item down'),
        ),
        const PopupMenuItem(value: 'edit', child: Text('Edit plan item')),
        const PopupMenuItem(value: 'remove', child: Text('Remove plan item')),
      ],
    );
  }

  Future<void> _managePlan() async {
    final start = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .75,
        child: SafeArea(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ListView(
              padding: NudgeTheme.pagePadding,
              children: [
                Text(
                  'Saved study plan',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _canEdit && controller.queue.isNotEmpty
                      ? () => Navigator.pop(sheetContext, true)
                      : null,
                  child: const Text('Start saved plan'),
                ),
                const SizedBox(height: 8),
                if (controller.queue.isEmpty) const Text('No saved plan items'),
                for (var i = 0; i < controller.queue.length; i++) _taskCard(i),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted && start == true) await _preparePlan();
  }

  Widget _taskCard(int index) {
    final task = controller.queue[index];
    final config = task.config;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 38,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '${controller.subject(task.subjectId).name} · '
                  '${config.focusMinutes} min focus · ${config.breakMinutes} min break · '
                  '${config.repeats} ${config.repeats == 1 ? 'session' : 'sessions'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _taskMenu(index),
        ],
      ),
    );
  }

  Widget _session() {
    final session = controller.active!;
    final remaining = controller.remaining;
    if (session.phase == SessionPhase.preparing) {
      final paused = session.isPaused;
      final canControl =
          controller.canAct && session.pausedPreparationMillis == null;
      return Padding(
        padding: NudgeTheme.pagePadding,
        child: Column(
          children: [
            Expanded(
              child: CountdownRing(
                remaining: remaining,
                total: session.phaseDuration,
                label: paused ? 'Preparation paused' : _phaseName,
                isPaused: paused,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: !canControl
                      ? null
                      : paused
                      ? controller.resumeSession
                      : () => controller.pauseSession(
                          expectedPhase: SessionPhase.preparing,
                        ),
                  child: Text(paused ? 'Resume' : 'Pause'),
                ),
                OutlinedButton(
                  onPressed: canControl ? controller.readyToFocus : null,
                  child: const Text('Skip preparation'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final focus = session.phase == SessionPhase.focus;
    final canSkip = controller.canAct && !session.isPaused;
    return ListView(
      key: ValueKey('session-${session.blockId}-${session.phase.name}'),
      padding: NudgeTheme.pagePadding,
      children: [
        Text(
          _phaseName,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          session.task?.title ?? controller.subject(session.subjectId).name,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (session.planned) ...[
          const SizedBox(height: 4),
          Text(
            '${controller.subject(session.subjectId).name} · ${session.taskIndex + 1}/${session.tasks.length}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (session.planned)
          Text(
            'Session ${session.repeatIndex + 1} of ${session.task!.config.repeats}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 24),
        CountdownRing(
          remaining: remaining,
          total: session.phaseDuration,
          label: _phaseName,
          isPaused: session.isPaused,
          action: IconButton.filled(
            tooltip: session.isPaused ? 'Resume timer' : 'Pause timer',
            onPressed:
                controller.canAct &&
                    (session.isPaused || remaining > Duration.zero)
                ? session.isPaused
                      ? controller.resumeSession
                      : controller.pauseSession
                : null,
            icon: Icon(
              session.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            ),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(48),
              shape: const CircleBorder(),
            ),
          ),
        ),
        if (session.isPaused) ...[
          const SizedBox(height: 8),
          const Center(child: Text('Paused')),
        ],
        const SizedBox(height: 24),
        if (session.task?.material != null) ...[
          Text(
            'Sample notes · demo quiz',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (session.task!.material!.isSample)
            TextButton(
              onPressed: () => showDemoNotes(context),
              child: const Text('Read demo notes'),
            ),
          const SizedBox(height: 12),
        ],
        if (!focus)
          FilledButton.icon(
            onPressed: canSkip ? controller.returnToStudy : null,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(session.planned ? 'Next session' : 'Continue'),
          ),
        const SizedBox(height: 8),
        Center(
          child: focus
              ? OutlinedButton.icon(
                  onPressed: controller.canAct ? controller.endSession : null,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(
                    controller.recallRun != null
                        ? 'I’m done studying'
                        : 'Finish',
                  ),
                )
              : TextButton(
                  onPressed: controller.canAct ? controller.endSession : null,
                  child: Text(
                    controller.recallRun != null
                        ? 'I’m done studying'
                        : 'Finish',
                  ),
                ),
        ),
        const SizedBox(height: 24),
        MusicPanel(controller: controller, compact: true),
        const SizedBox(height: 4),
        ProtectionPanel(controller: controller, compact: true),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _history() => ListView(
    key: const PageStorageKey('history'),
    padding: NudgeTheme.pagePadding,
    children: [
      Text('Study time', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 8),
      const SizedBox(height: 16),
      if (controller.historySubjects.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('No sessions yet'),
        ),
      for (final subject in controller.historySubjects)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    subject.isDeleted
                        ? '${subject.name} · Deleted task'
                        : subject.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    '${formatMinutes(controller.totalSeconds(subject.id))} min',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      RecallHistoryList(controller: controller),
    ],
  );
}

class StudyTaskDialog extends StatefulWidget {
  const StudyTaskDialog({super.key, required this.controller, this.existing});
  final SessionController controller;
  final Subject? existing;
  @override
  State<StudyTaskDialog> createState() => _StudyTaskDialogState();
}

class _StudyTaskDialogState extends State<StudyTaskDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    if (!widget.controller.canAct) {
      setState(() => _error = 'Finish retrying local storage first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        await widget.controller.addSubject(_name.text, Priority.medium);
      } else {
        await widget.controller.editSubject(
          existing.id,
          _name.text,
          existing.priority,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the task. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(widget.existing == null ? 'Add task' : 'Edit task'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                maxLength: 80,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Task name'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a task name.'
                    : null,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
  );
}
