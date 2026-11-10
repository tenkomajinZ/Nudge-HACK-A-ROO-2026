import 'package:flutter/material.dart';

import 'focus_widgets.dart';
import 'models.dart';
import 'nudge_theme.dart';
import 'recall_models.dart';
import 'recall_widgets.dart';
import 'session_controller.dart';

typedef StartStudy =
    Future<bool> Function(TimerConfig config, RecallMaterial? material);

Future<void> _advance(BuildContext context, Widget page) async {
  if (ModalRoute.of(context)?.isCurrent != true) return;
  final started = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => page));
  if (started == true && context.mounted) Navigator.pop(context, true);
}

class StudyMethodPage extends StatelessWidget {
  const StudyMethodPage({
    super.key,
    required this.taskName,
    required this.controller,
    required this.onStart,
  });

  final String taskName;
  final SessionController controller;
  final StartStudy onStart;

  @override
  Widget build(BuildContext context) => _SetupPage(
    title: 'Study method',
    children: [
      Text(
        'How do you want to study $taskName?',
        style: Theme.of(context).textTheme.headlineMedium,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      LayoutBuilder(
        builder: (context, constraints) {
          const gap = 12.0;
          final minimum = MediaQuery.textScalerOf(context).scale(128);
          final width = constraints.maxWidth >= minimum * 2 + gap
              ? (constraints.maxWidth - gap) / 2
              : constraints.maxWidth;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final recall in [false, true])
                SizedBox(
                  width: width,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 100),
                      padding: const EdgeInsets.all(16),
                      textStyle: Theme.of(context).textTheme.titleMedium,
                    ),
                    onPressed: () => _advance(
                      context,
                      recall
                          ? _MaterialsPage(
                              taskName: taskName,
                              controller: controller,
                              onStart: onStart,
                            )
                          : RhythmPage(
                              taskName: taskName,
                              controller: controller,
                              onStart: onStart,
                            ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          recall ? Icons.quiz_outlined : Icons.timer_outlined,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          recall ? 'Active Recall' : 'Focus',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );
}

class _MaterialsPage extends StatelessWidget {
  const _MaterialsPage({
    required this.taskName,
    required this.controller,
    required this.onStart,
  });

  final String taskName;
  final SessionController controller;
  final StartStudy onStart;

  @override
  Widget build(BuildContext context) => _SetupPage(
    title: 'Study materials',
    children: [
      Text(
        'Try Active Recall for $taskName',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      const Text('Study the included sample notes, then try an offline quiz.'),
      const SizedBox(height: 20),
      OutlinedButton(
        onPressed: () => showDemoNotes(context),
        child: const Text('Read sample notes'),
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: () => _advance(
          context,
          RhythmPage(
            taskName: taskName,
            material: RecallMaterial.sample,
            controller: controller,
            onStart: onStart,
          ),
        ),
        child: const Text('Use sample notes'),
      ),
    ],
  );
}

class RhythmPage extends StatefulWidget {
  const RhythmPage({
    super.key,
    required this.taskName,
    required this.controller,
    required this.onStart,
    this.material,
    this.savedPlan = false,
  });

  final String taskName;
  final SessionController controller;
  final StartStudy onStart;
  final RecallMaterial? material;
  final bool savedPlan;

  @override
  State<RhythmPage> createState() => _RhythmPageState();
}

class _RhythmPageState extends State<RhythmPage> {
  TimerConfig _config = const TimerConfig();
  bool _starting = false;
  String? _error;

  Future<void> _start() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final started = await widget.onStart(_config, widget.material);
      if (!mounted) return;
      if (started) {
        Navigator.pop(context, true);
      } else {
        setState(
          () => _error = widget.controller.error ?? 'Try starting again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not start studying. Try again.');
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_starting,
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => _SetupPage(
        title: widget.savedPlan ? 'Study plan setup' : 'Choose your rhythm',
        children: [
          Text(
            widget.taskName,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (widget.material case final material?) Text(material.name),
          if (widget.savedPlan)
            const Text('Your saved tasks use their own focus and break times.'),
          const SizedBox(height: 16),
          if (!widget.savedPlan)
            RhythmControls(onChanged: (config) => _config = config),
          const SizedBox(height: 16),
          MusicPanel(controller: widget.controller, compact: true),
          ProtectionPanel(controller: widget.controller, setup: true),
          const SizedBox(height: 16),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          FilledButton(
            onPressed: _starting || !widget.controller.canAct ? null : _start,
            child: Text(_starting ? 'Starting…' : 'Start preparation'),
          ),
        ],
      ),
    ),
  );
}

class _SetupPage extends StatelessWidget {
  const _SetupPage({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: SingleChildScrollView(
            padding: NudgeTheme.pagePadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    ),
  );
}
