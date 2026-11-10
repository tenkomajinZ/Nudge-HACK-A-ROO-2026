import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'session_controller.dart';
import 'focus_services.dart';
import 'nudge_theme.dart';
import 'recall_models.dart';
import 'recall_widgets.dart';

class CountdownRing extends StatefulWidget {
  const CountdownRing({
    super.key,
    required this.remaining,
    required this.total,
    required this.label,
    this.isPaused = false,
    this.action,
  });
  final Duration remaining, total;
  final String label;
  final bool isPaused;
  final Widget? action;

  double get _ratio => total.inMilliseconds <= 0
      ? 0.0
      : (remaining.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

  @override
  State<CountdownRing> createState() => _CountdownRingState();
}

class _CountdownRingState extends State<CountdownRing>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(vsync: this, value: widget._ratio);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.isPaused && MediaQuery.disableAnimationsOf(context)) {
      _progress.value = widget._ratio;
    }
  }

  @override
  void didUpdateWidget(CountdownRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPaused) {
      _progress.stop();
    } else if (oldWidget.isPaused || widget._ratio != oldWidget._ratio) {
      _progress.animateTo(
        widget._ratio,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 900),
      );
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.remaining;
    final action = widget.action;
    final countdown = Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Semantics(
                label:
                    '${widget.label}, ${formatCountdown(remaining)} remaining',
                child: ExcludeSemantics(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatCountdown(remaining),
                      style: const TextStyle(
                        fontSize: 68,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (action != null) ...[const SizedBox(height: 8), action],
          ],
        ),
      ),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 292),
        child: AspectRatio(
          aspectRatio: 1,
          child: AnimatedBuilder(
            animation: _progress,
            child: countdown,
            builder: (context, child) => CustomPaint(
              painter: _RingPainter(
                _progress.value,
                Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xfffaf7ff)
                    : Theme.of(context).colorScheme.primary,
                Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xffae42bc)
                    : Theme.of(context).colorScheme.primaryContainer,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.ratio, this.foreground, this.background);
  final double ratio;
  final Color foreground, background;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = rect.deflate(10);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..color = background;
    canvas.drawOval(circle, paint);
    if (ratio > 0) {
      paint.color = foreground;
      // Anchored at twelve: the endpoint retreats counterclockwise toward it.
      canvas.drawArc(circle, -math.pi / 2, 2 * math.pi * ratio, false, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.ratio != ratio ||
      old.foreground != foreground ||
      old.background != background;
}

class RhythmControls extends StatefulWidget {
  const RhythmControls({
    super.key,
    this.initial = const TimerConfig(),
    required this.onChanged,
  });

  final TimerConfig initial;
  final ValueChanged<TimerConfig> onChanged;

  @override
  State<RhythmControls> createState() => _RhythmControlsState();
}

class _RhythmControlsState extends State<RhythmControls> {
  static const _presets = [
    ('Gentle Start', 10, 5),
    ('Pomodoro', 25, 5),
    ('Long Focus', 50, 10),
  ];
  static const _custom = 3;

  late int _preset, _focus, _rest, _repeats;

  @override
  void initState() {
    super.initState();
    final config = widget.initial;
    _focus = config.focusMinutes;
    _rest = config.breakMinutes;
    _repeats = config.repeats;
    final match = _presets.indexWhere(
      (preset) => preset.$2 == _focus && preset.$3 == _rest,
    );
    _preset = match < 0 ? _custom : match;
  }

  void _change(VoidCallback update) {
    setState(update);
    widget.onChanged(
      TimerConfig(
        focusMinutes: _preset == _custom ? _focus : _presets[_preset].$2,
        breakMinutes: _preset == _custom ? _rest : _presets[_preset].$3,
        repeats: _repeats,
      ),
    );
  }

  Widget _presetCards(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 8.0;
      final minimum = MediaQuery.textScalerOf(context).scale(126);
      final width = constraints.maxWidth;
      final columns = width >= minimum * 4 + gap * 3
          ? 4
          : width >= minimum * 2 + gap
          ? 2
          : 1;
      final cardWidth = (width - gap * (columns - 1)) / columns;
      final colors = Theme.of(context).colorScheme;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (var i = 0; i <= _custom; i++)
            SizedBox(
              width: cardWidth,
              child: ChoiceChip(
                label: SizedBox(
                  width: double.infinity,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 52),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            i == _custom ? 'Custom' : _presets[i].$1,
                            textAlign: TextAlign.center,
                          ),
                          if (i != _custom)
                            Text(
                              '${_presets[i].$2} / ${_presets[i].$3} min',
                              semanticsLabel:
                                  '${_presets[i].$2} minutes of focus, '
                                  '${_presets[i].$3} minutes of break',
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                selected: _preset == i,
                showCheckmark: false,
                selectedColor: colors.primary,
                labelStyle: TextStyle(
                  color: _preset == i ? colors.onPrimary : colors.onSurface,
                ),
                onSelected: (_) => _change(() => _preset = i),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
        ],
      );
    },
  );

  Widget _durationSlider({
    required String label,
    required String key,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$label · $value min',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Semantics(
        label: '$label duration',
        child: Slider(
          key: ValueKey(key),
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value min',
          semanticFormatterCallback: (value) => '${value.round()} minutes',
          onChanged: (value) => _change(() => onChanged(value.round())),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _presetCards(context),
      if (_preset == _custom) ...[
        const SizedBox(height: 16),
        _durationSlider(
          label: 'Focus',
          key: 'focus-minutes',
          value: _focus,
          min: 1,
          max: 180,
          onChanged: (value) => _focus = value,
        ),
        _durationSlider(
          label: 'Break',
          key: 'break-minutes',
          value: _rest,
          min: 0,
          max: 60,
          onChanged: (value) => _rest = value,
        ),
      ],
      const SizedBox(height: 24),
      Text(
        'Number of sessions',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          IconButton.outlined(
            tooltip: 'Remove a session',
            onPressed: _repeats > 1 ? () => _change(() => _repeats--) : null,
            icon: const Icon(Icons.remove_rounded),
          ),
          SizedBox(
            width: 56,
            child: Semantics(
              liveRegion: true,
              label: '$_repeats sessions',
              excludeSemantics: true,
              child: Text('$_repeats', textAlign: TextAlign.center),
            ),
          ),
          IconButton.outlined(
            tooltip: 'Add a session',
            onPressed: _repeats < 12 ? () => _change(() => _repeats++) : null,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    ],
  );
}

class PlanItemDialog extends StatefulWidget {
  const PlanItemDialog({
    super.key,
    required this.subjects,
    required this.controller,
    required this.existing,
  });
  final List<Subject> subjects;
  final SessionController controller;
  final FocusTask existing;
  @override
  State<PlanItemDialog> createState() => _PlanItemDialogState();
}

class _PlanItemDialogState extends State<PlanItemDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late int _subject;
  late TimerConfig _config;
  RecallMaterial? _material;
  @override
  void initState() {
    super.initState();
    final task = widget.existing;
    _material = task.material;
    _subject = task.subjectId;
    _title = TextEditingController(text: task.title);
    _config = task.config;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final invalid = _form.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      final first = invalid.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !first.mounted) return;
        Scrollable.ensureVisible(
          first.context,
          alignment: .1,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 200),
        );
      });
      return;
    }
    Navigator.pop(
      context,
      FocusTask(
        id: widget.existing.id,
        subjectId: _subject,
        title: _title.text.trim(),
        material: _material,
        config: _config,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Edit plan item')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              padding: NudgeTheme.pagePadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<int>(
                    initialValue: _subject,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Linked task'),
                    items: widget.subjects
                        .map(
                          (s) => DropdownMenuItem(
                            value: s.id,
                            child: Text(s.name),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => _subject = value!,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _title,
                    maxLength: 120,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Plan item name',
                    ),
                    validator: (text) => text == null || text.trim().isEmpty
                        ? 'Enter a plan item name.'
                        : null,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Rhythm',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  RhythmControls(
                    initial: _config,
                    onChanged: (value) => _config = value,
                  ),
                  const SizedBox(height: 24),
                  RecallSetup(
                    initial: _material,
                    onChanged: (value) => _material = value,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _submit,
                    child: const Text('Save plan item'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _DetailPanel extends StatefulWidget {
  const _DetailPanel({
    required this.title,
    required this.summary,
    required this.icon,
    required this.child,
    required this.compact,
    this.trailing,
    this.keepSummary = false,
  });
  final String title, summary;
  final IconData icon;
  final Widget child;
  final bool compact, keepSummary;
  final Widget? trailing;
  @override
  State<_DetailPanel> createState() => _DetailPanelState();
}

class _DetailPanelState extends State<_DetailPanel> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                expanded: widget.compact ? _expanded : null,
                child: ListTile(
                  onTap: widget.compact
                      ? () => setState(() => _expanded = !_expanded)
                      : null,
                  leading: Icon(widget.icon, size: 22),
                  title: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  subtitle: widget.keepSummary || widget.compact && !_expanded
                      ? Text(
                          widget.summary,
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : null,
                  trailing: widget.compact
                      ? Icon(_expanded ? Icons.expand_less : Icons.expand_more)
                      : null,
                ),
              ),
            ),
            if (widget.trailing != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: widget.trailing!,
              ),
          ],
        ),
        Visibility(
          visible: !widget.compact || _expanded,
          maintainState: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: widget.child,
          ),
        ),
      ],
    ),
  );
}

class ProtectionPanel extends StatefulWidget {
  const ProtectionPanel({
    super.key,
    required this.controller,
    this.compact = false,
    this.setup = false,
  });
  final SessionController controller;
  final bool compact, setup;
  @override
  State<ProtectionPanel> createState() => _ProtectionPanelState();
}

class _ProtectionPanelState extends State<ProtectionPanel>
    with WidgetsBindingObserver {
  bool _opening = false;
  SessionController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.services.refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) controller.services.refreshStatus();
  }

  Future<void> _openPermission(String permission) async {
    setState(() => _opening = true);
    try {
      await controller.services.openPermission(permission);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.services,
    builder: (context, _) {
      final status = controller.services.status;
      return _DetailPanel(
        title: widget.setup ? 'Make room for focus' : 'Protection',
        summary:
            status.message ??
            (!status.supported
                ? 'Android only'
                : status.dndActive
                ? 'On'
                : 'Off'),
        icon: Icons.shield_outlined,
        compact: widget.compact,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  status.dndActive
                      ? Icons.do_not_disturb_on
                      : Icons.notifications_none,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status.dndActive
                        ? 'DND active for this study run'
                        : !status.supported
                        ? 'Device controls available on Android'
                        : !status.dndAccess
                        ? widget.setup
                              ? 'Allow Do Not Disturb to quiet notifications while you study.'
                              : 'DND permission not granted'
                        : !status.alarmAccess
                        ? 'Allow timer endings to turn off study protections on time.'
                        : 'DND ready for your next session',
                  ),
                ),
              ],
            ),
            if (status.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(status.message!),
              ),
            if (widget.setup &&
                status.supported &&
                (!status.dndAccess || !status.alarmAccess)) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (!status.dndAccess)
                    TextButton(
                      onPressed: _opening ? null : () => _openPermission('dnd'),
                      child: const Text('Allow DND'),
                    ),
                  if (!status.alarmAccess)
                    TextButton(
                      onPressed: _opening
                          ? null
                          : () => _openPermission('alarm'),
                      child: const Text('Allow timer endings'),
                    ),
                ],
              ),
            ],
          ],
        ),
      );
    },
  );
}

class MusicPanel extends StatefulWidget {
  const MusicPanel({super.key, required this.controller, this.compact = false});
  final SessionController controller;
  final bool compact;
  @override
  State<MusicPanel> createState() => _MusicPanelState();
}

class _MusicPanelState extends State<MusicPanel> {
  SessionController get controller => widget.controller;
  double? _volumePreview;
  int _volumeRevision = 0;
  double? _seekPreview;
  int? _seekTrack;
  int _seekRevision = 0;

  @override
  void dispose() {
    if (controller.active == null) {
      controller.services.music('stopPreview');
    }
    super.dispose();
  }

  String _time(double milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void _play() {
    final audio = controller.services;
    audio.music(
      controller.active == null && audio.duration == Duration.zero
          ? 'preview'
          : 'toggle',
      track: controller.settings.track,
      volume: controller.settings.volume,
    );
  }

  Widget _playButton() => IconButton(
    tooltip: controller.services.playing ? 'Pause music' : 'Play music',
    onPressed: controller.canAct ? _play : null,
    icon: Icon(
      controller.services.playing
          ? Icons.pause_circle_filled
          : Icons.play_circle_fill,
    ),
    iconSize: 36,
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.services,
    builder: (context, _) {
      final audio = controller.services;
      final chosen = controller.settings.track;
      final duration = audio.duration.inMilliseconds.toDouble();
      final canSeek = audio.seekable && duration > 0;
      final position =
          (_seekTrack == audio.currentTrack ? _seekPreview : null) ??
          audio.position.inMilliseconds.toDouble();
      return _DetailPanel(
        title: 'Music',
        keepSummary: true,
        summary:
            audio.audioError ??
            (chosen < 0
                ? 'Silence'
                : '${studyTracks[audio.duration == Duration.zero ? chosen : audio.currentTrack]} · ${audio.playing ? "Playing" : "Paused"}'),
        icon: Icons.music_note_outlined,
        compact: widget.compact,
        trailing: widget.compact && chosen >= 0 ? _playButton() : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: ValueKey(chosen),
              initialValue: chosen,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Track'),
              items: [
                const DropdownMenuItem(value: -1, child: Text('Silence')),
                for (var i = 0; i < studyTracks.length; i++)
                  DropdownMenuItem(value: i, child: Text(studyTracks[i])),
              ],
              onChanged: controller.canAct
                  ? (value) => controller.updateSettings(
                      controller.settings.copyWith(track: value!),
                    )
                  : null,
            ),
            if (chosen >= 0) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous song',
                    onPressed: () => audio.music('previous'),
                    icon: const Icon(Icons.skip_previous),
                  ),
                  if (!widget.compact) _playButton(),
                  IconButton(
                    tooltip: 'Next song',
                    onPressed: () => audio.music('next'),
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
              Slider(
                key: const ValueKey('music-seek'),
                value: canSeek ? position.clamp(0, duration) : 0,
                max: canSeek ? duration : 1,
                label: _time(position),
                semanticFormatterCallback: (value) =>
                    '${_time(value)} of ${_time(duration)}',
                onChangeStart: canSeek
                    ? (_) {
                        _seekRevision++;
                        _seekTrack = audio.currentTrack;
                      }
                    : null,
                onChanged: canSeek
                    ? (value) => setState(() => _seekPreview = value)
                    : null,
                onChangeEnd: canSeek
                    ? (value) async {
                        final revision = _seekRevision;
                        final track = _seekTrack;
                        try {
                          if (track != null) {
                            await audio.seek(
                              Duration(milliseconds: value.round()),
                              track: track,
                            );
                          }
                        } finally {
                          if (mounted && revision == _seekRevision) {
                            setState(() {
                              _seekPreview = null;
                              _seekTrack = null;
                            });
                          }
                        }
                      }
                    : null,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      _time(position),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _time(duration),
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Volume'),
              Slider(
                key: const ValueKey('music-volume'),
                value: _volumePreview ?? controller.settings.volume,
                label: 'Music volume',
                semanticFormatterCallback: (value) =>
                    '${(value * 100).round()} percent',
                onChangeStart: (_) => _volumeRevision++,
                onChanged: controller.ready && controller.error == null
                    ? (value) {
                        setState(() => _volumePreview = value);
                        controller.previewVolume(value);
                      }
                    : null,
                onChangeEnd: (value) async {
                  final revision = _volumeRevision;
                  await controller.persistVolume();
                  if (mounted && revision == _volumeRevision) {
                    setState(() => _volumePreview = null);
                  }
                },
              ),
            ],
            if (audio.audioError != null) Text(audio.audioError!),
          ],
        ),
      );
    },
  );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: NudgeTheme.pagePadding,
              children: [
                DropdownButtonFormField<Appearance>(
                  key: ValueKey(controller.settings.appearance),
                  initialValue: controller.settings.appearance,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Appearance'),
                  items: const [
                    DropdownMenuItem(
                      value: Appearance.light,
                      child: Text('Light'),
                    ),
                    DropdownMenuItem(
                      value: Appearance.dark,
                      child: Text('Dark'),
                    ),
                    DropdownMenuItem(
                      value: Appearance.system,
                      child: Text('Follow system'),
                    ),
                  ],
                  onChanged: controller.canAct
                      ? (value) => controller.updateSettings(
                          controller.settings.copyWith(appearance: value),
                        )
                      : null,
                ),
                const SizedBox(height: 20),
                ProtectionPanel(controller: controller),
                MusicPanel(controller: controller),
                const SizedBox(height: 20),
                ExpansionTile(
                  title: const Text('About'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nudge · Hackaroo Demo',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Study history is saved on this device. The demo quiz uses bundled sample notes.',
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Music credits',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'J. S. Bach · Open Goldberg Variations\nPiano: Kimiko Ishizaka · Public-domain recording.\nopengoldbergvariations.org',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
