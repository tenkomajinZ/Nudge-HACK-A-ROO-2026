import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'recall_models.dart';
import 'session_controller.dart';
import 'nudge_theme.dart';
import 'hold_to_submit_button.dart';

Future<void> showDemoNotes(BuildContext context) async {
  final notes = await rootBundle.loadString('assets/recall/demo_notes.txt');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Demonstration notes'),
      scrollable: true,
      content: Text(notes),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Back'),
        ),
      ],
    ),
  );
}

class RecallSetup extends StatelessWidget {
  const RecallSetup({super.key, this.initial, required this.onChanged});

  final RecallMaterial? initial;
  final ValueChanged<RecallMaterial?> onChanged;

  @override
  Widget build(BuildContext context) => FormField<RecallMaterial>(
    initialValue: initial,
    builder: (field) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Study mode', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final (material, label) in const [
              (null, 'Focus'),
              (RecallMaterial.sample, 'Active Recall'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: (field.value != null) == (material != null),
                onSelected: (_) {
                  field.didChange(material);
                  onChanged(material);
                },
              ),
          ],
        ),
        if (field.value != null)
          TextButton(
            onPressed: () => showDemoNotes(context),
            child: const Text('Read sample notes'),
          ),
      ],
    ),
  );
}

class RecallScreen extends StatefulWidget {
  const RecallScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<RecallScreen> createState() => _RecallScreenState();
}

class _RecallScreenState extends State<RecallScreen> {
  SessionController get controller => widget.controller;
  final _scrollController = ScrollController();
  bool _acting = false;
  bool get acting => _acting || controller.recallGradingBusy;
  bool _confirmationOpen = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    if (acting) return;
    setState(() => _acting = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _next(RecallRun run) async {
    FocusScope.of(context).unfocus();
    if (run.currentQuestionIndex < run.quiz!.questions.length - 1) {
      await _act(() => controller.nextRecallQuestion(run.currentQuestion!.id));
    } else if (run.incompleteCount > 0) {
      await _navigate(
        run,
        run.quiz!.questions.firstWhere((q) => !q.isAnswered(run.answers)).id,
      );
    } else {
      await _act(() => controller.submitRecall(runId: run.id));
    }
    _scrollToStart();
  }

  void _scrollToStart() {
    if (mounted && _scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Future<void> _navigate(RecallRun run, String questionId) async {
    FocusScope.of(context).unfocus();
    await _act(
      () => controller.goToRecallQuestion(
        questionId,
        fromQuestionId: run.currentQuestion!.id,
      ),
    );
    _scrollToStart();
  }

  Future<void> _showQuestions(RecallRun run) async {
    FocusScope.of(context).unfocus();
    final index = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .75,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Questions',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close question list',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _questionList(
                  run,
                  (index) => Navigator.pop(context, index),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && index != null && controller.recallRun?.id == run.id) {
      await _navigate(run, run.quiz!.questions[index].id);
    }
  }

  Widget _questionList(RecallRun run, ValueChanged<int> select) =>
      ListView.builder(
        itemCount: run.quiz!.questions.length,
        itemBuilder: (context, index) {
          final q = run.quiz!.questions[index];
          final checked = run.checkedQuestionIds.contains(q.id);
          final started = q.parts.any(
            (p) => (run.answers['${q.id}/${p.id}'] ?? '').trim().isNotEmpty,
          );
          final status = checked
              ? 'Checked'
              : q.isAnswered(run.answers)
              ? 'Answered'
              : started
              ? 'In progress'
              : 'Unanswered';
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              selected: index == run.currentQuestionIndex,
              selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
              title: Text('Question ${index + 1}'),
              subtitle: Text(status),
              trailing: Icon(
                checked
                    ? Icons.lock_outline
                    : q.isAnswered(run.answers)
                    ? Icons.task_alt
                    : started
                    ? Icons.edit_outlined
                    : Icons.radio_button_unchecked,
              ),
              onTap: acting || !controller.canAct ? null : () => select(index),
            ),
          );
        },
      );

  Future<void> _submitEarly(RecallRun run) async {
    if (_confirmationOpen || acting || !controller.canAct) return;
    _confirmationOpen = true;
    FocusScope.of(context).unfocus();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Submit early?'),
          scrollable: true,
          content: Text(
            '${run.incompleteCount} ${run.incompleteCount == 1 ? 'question remains' : 'questions remain'} incomplete. Entered answers will be graded, including partial answers. Blank answers count as incorrect. You cannot change answers after submitting.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep answering'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Submit answers'),
            ),
          ],
        ),
      );
      if (mounted && confirmed == true) {
        await _act(
          () => controller.submitRecall(runId: run.id, allowIncomplete: true),
        );
        _scrollToStart();
      }
    } finally {
      _confirmationOpen = false;
    }
  }

  Future<void> _review(RecallRun run) async {
    final quiz = run.quiz!;
    final seconds = controller.blocks
        .where((b) => b.runId == run.id)
        .fold<int>(0, (sum, b) => sum + b.focusSeconds);
    final estimate =
        ((seconds /
                        60 *
                        (1 -
                            quiz.score(run.answers, grades: run.grades) / 100) /
                        5)
                    .ceil() *
                5)
            .clamp(5, 30);
    final input = TextEditingController(text: '$estimate');
    final form = GlobalKey<FormState>();
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('A focused review'),
        scrollable: true,
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$estimate minutes per task is a starting estimate based on your study time and missed questions. Adjust it to suit you.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: input,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Review minutes per task',
                ),
                validator: (value) {
                  final n = int.tryParse(value ?? '');
                  return n == null || n < 1 || n > 180
                      ? 'Choose 1–180 minutes.'
                      : null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, int.parse(input.text));
              }
            },
            child: const Text('Start review'),
          ),
        ],
      ),
    );
    if (mounted) await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (minutes != null) await _act(() => controller.studyAgain(minutes));
  }

  @override
  Widget build(BuildContext context) {
    final run = controller.recallRun;
    // Finishing clears the run before storage completes and the parent rebuilds.
    if (run == null) return const SizedBox.shrink();
    final content = ListView(
      key: ValueKey('recall-${run.id}-${run.stage}'),
      controller: _scrollController,
      padding: NudgeTheme.pagePadding,
      children: [
        if (run.stage != 'answering')
          Text(
            run.stage == 'choice'
                ? 'Ready to recall?'
                : run.stage == 'submitted'
                ? 'Your recall results'
                : 'Active Recall',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        if (run.stage != 'answering') const SizedBox(height: 12),
        if (run.quiz?.simulated == true ||
            run.entries.any((e) => e.quiz?.simulated == true))
          Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('DEMO · These questions use bundled sample notes.'),
            ),
          ),
        if (run.stage == 'choice') ...[
          const Text(
            'Study time saved. Try ten questions or keep studying. The quiz samples key concepts, not every detail.',
          ),
          const SizedBox(height: 16),
          for (final entry in run.entries.where(
            (e) => controller.blocks.any(
              (b) =>
                  b.runId == run.id &&
                  b.taskId == e.taskId &&
                  b.focusSeconds > 0,
            ),
          ))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                run.tasks.firstWhere((t) => t['id'] == entry.taskId)['title']
                    as String,
              ),
              subtitle: Text(
                entry.error ??
                    (entry.quiz != null
                        ? 'Questions ready'
                        : 'Preparing questions…'),
              ),
              leading: Icon(
                entry.quiz != null
                    ? Icons.check_circle_outline
                    : entry.state == 'failed'
                    ? Icons.error_outline
                    : Icons.hourglass_empty,
              ),
            ),
          if (!controller.recallReady &&
              run.entries.any((e) => e.state == 'failed'))
            OutlinedButton(
              onPressed: acting ? null : () => _act(controller.retryRecall),
              child: const Text('Retry preparation'),
            ),
          FilledButton(
            onPressed: acting || !controller.canAct || !controller.recallReady
                ? null
                : () => _act(controller.startRecall),
            child: const Text('Start recall'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: acting || !controller.canAct
                ? null
                : () => _act(controller.keepStudying),
            child: const Text('Keep studying'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: acting || !controller.canAct
                ? null
                : () => _act(controller.finishRecall),
            child: const Text('Finish without recall'),
          ),
        ],
        if (run.stage == 'answering') ...[
          const Text(
            'Try without notes. Check an answer for feedback, or move between questions and return later.',
          ),
          const SizedBox(height: 12),
          if (controller.recallGradingBusy)
            Semantics(
              liveRegion: true,
              label: 'Checking answer',
              child: const LinearProgressIndicator(),
            ),
          if (controller.recallGradingMessage != null)
            Semantics(
              liveRegion: true,
              child: Text(controller.recallGradingMessage!),
            ),
          Text(
            'Question ${run.currentQuestionIndex + 1} of ${run.quiz!.questions.length}',
          ),
          _question(run, run.currentQuestion!, run.currentQuestionIndex),
          const SizedBox(height: 16),
          FilledButton(
            onPressed:
                acting ||
                    !controller.canAct ||
                    run.answerChecked ||
                    !run.currentQuestion!.isAnswered(run.answers)
                ? null
                : () {
                    FocusScope.of(context).unfocus();
                    _act(
                      () =>
                          controller.checkRecallAnswer(run.currentQuestion!.id),
                    );
                  },
            child: Text(
              controller.recallGradingBusy
                  ? 'Checking answer…'
                  : run.answerChecked
                  ? 'Answer checked'
                  : 'Check answer',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: acting || !controller.canAct ? null : () => _next(run),
            child: Text(
              run.currentQuestionIndex < run.quiz!.questions.length - 1
                  ? 'Next question'
                  : run.incompleteCount > 0
                  ? 'Review unanswered'
                  : 'Submit answers',
            ),
          ),
          const SizedBox(height: 24),
          HoldToSubmitButton(
            key: ValueKey('submit-${run.id}-${run.currentQuestionIndex}'),
            enabled: !acting && controller.canAct,
            onHeld: () => _submitEarly(run),
          ),
          const SizedBox(height: 8),
          const Text(
            'Hold for 2 seconds to open confirmation.',
            textAlign: TextAlign.center,
          ),
        ],
        if (run.stage == 'submitted') ..._results(run),
      ],
    );
    if (run.stage != 'answering') return content;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        final title = Text(
          'Active Recall',
          style: Theme.of(context).textTheme.headlineMedium,
        );
        final opener = TextButton.icon(
          onPressed: acting || !controller.canAct
              ? null
              : () => _showQuestions(run),
          icon: const Icon(Icons.format_list_numbered),
          label: const Text('Questions'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        );
        final stackHeader =
            !wide &&
            constraints.maxWidth < 600 &&
            MediaQuery.textScalerOf(context).scale(16) > 24;
        final questions = Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: stackHeader
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        title,
                        Align(alignment: Alignment.centerRight, child: opener),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: title),
                        if (!wide) opener,
                      ],
                    ),
            ),
            Expanded(child: content),
          ],
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: questions),
            if (wide)
              SizedBox(
                width: 256,
                child: Card(
                  margin: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Questions',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      Expanded(
                        child: _questionList(
                          run,
                          (index) =>
                              _navigate(run, run.quiz!.questions[index].id),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _question(RecallRun run, RecallQuestion question, int index) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${index + 1}. ${question.prompt}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          for (final part in question.parts) ...[
            Text(part.prompt),
            const SizedBox(height: 8),
            if (part.kind == 'choice')
              _choices(run, question, part)
            else ...[
              TextFormField(
                key: ValueKey('${run.id}-${question.id}-${part.id}'),
                initialValue: run.answers['${question.id}/${part.id}'] ?? '',
                style: run.answerChecked
                    ? TextStyle(color: Theme.of(context).colorScheme.onSurface)
                    : null,
                enabled:
                    !run.answerChecked && !acting && controller.error == null,
                decoration: InputDecoration(
                  labelText: 'Your answer',
                  suffixIcon: run.answerChecked
                      ? _answerIcon(
                          part.isCorrect(
                            run.answers['${question.id}/${part.id}'],
                            run.grades['${question.id}/${part.id}'],
                          ),
                        )
                      : null,
                ),
                onChanged: (value) => controller.setRecallAnswer(
                  '${question.id}/${part.id}',
                  value,
                ),
              ),
              if (run.answerChecked)
                Text(
                  part.isCorrect(
                        run.answers['${question.id}/${part.id}'],
                        run.grades['${question.id}/${part.id}'],
                      )
                      ? 'Correct'
                      : 'Correct answer: ${part.solution}',
                ),
              if (run.grades['${question.id}/${part.id}']?.source == 'self' &&
                  run.answerChecked)
                const Text('Self-reviewed'),
              if (run.grades['${question.id}/${part.id}']?.appliesTo(
                        run.answers['${question.id}/${part.id}'],
                      ) ==
                      true &&
                  run.grades['${question.id}/${part.id}']?.verdict ==
                      'uncertain') ...[
                Semantics(
                  liveRegion: true,
                  child: Text('Could not check answer'),
                ),
                OutlinedButton(
                  onPressed: acting || !controller.canAct
                      ? null
                      : () => _act(
                          () => controller.retryRecallGrading(question.id),
                        ),
                  child: const Text('Retry grading'),
                ),
              ],
            ],
            const SizedBox(height: 12),
          ],
          if (run.answerChecked)
            Semantics(
              liveRegion: true,
              child: question.points(run.answers, grades: run.grades) == 1
                  ? const Text('Good job!')
                  : Text(question.explanation),
            ),
        ],
      ),
    ),
  );

  Widget _answerIcon(bool correct) => Icon(
    correct ? Icons.check_circle : Icons.cancel,
    color: correct
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error,
    semanticLabel: correct ? 'Correct' : 'Incorrect',
  );

  Widget _choices(RecallRun run, RecallQuestion question, RecallPart part) {
    final selected = run.answers['${question.id}/${part.id}'];
    final options = part.options.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Choose the right answer:'),
        RadioGroup<String>(
          groupValue: selected,
          onChanged: (value) {
            if (value != null &&
                !run.answerChecked &&
                !acting &&
                controller.canAct) {
              controller.setRecallAnswer('${question.id}/${part.id}', value);
            }
          },
          child: Column(
            children: [
              for (var i = 0; i < options.length; i++)
                RadioListTile<String>(
                  value: options[i].key,
                  enabled: !run.answerChecked && !acting && controller.canAct,
                  title: Text(
                    '${String.fromCharCode(97 + i)}. ${options[i].value}',
                    style: run.answerChecked
                        ? TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                          )
                        : null,
                  ),
                  tileColor: run.answerChecked && options[i].key == part.correct
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  subtitle:
                      run.answerChecked &&
                          (options[i].key == selected ||
                              options[i].key == part.correct)
                      ? Text(
                          options[i].key == part.correct
                              ? 'Correct answer'
                              : 'Incorrect',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        )
                      : null,
                  secondary:
                      run.answerChecked &&
                          (options[i].key == selected ||
                              options[i].key == part.correct)
                      ? _answerIcon(options[i].key == part.correct)
                      : null,
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _results(RecallRun run) {
    final score = run.quiz!.score(run.answers, grades: run.grades),
        tier = recallTier(score);
    final feedback = switch (tier) {
      'perfect' => 'You recalled all ten questions correctly. Great work!',
      'veryGood' =>
        'Very good! A short review can help with the remaining gaps.',
      'almost' =>
        'Almost there. Give the missed concepts another focused pass.',
      _ =>
        'You have a starting point. Let’s work through the missed concepts together.',
    };
    return [
      Text(
        '${score.toStringAsFixed(score % 1 == 0 ? 0 : 1)}%',
        style: Theme.of(context).textTheme.displaySmall,
      ),
      const SizedBox(height: 8),
      Text(feedback),
      const SizedBox(height: 8),
      const Text(
        'This score describes this quiz, not complete mastery of the material.',
      ),
      const SizedBox(height: 20),
      SizedBox(
        height: tier == 'review'
            ? 64
            : tier == 'almost'
            ? 56
            : 48,
        child: FilledButton(
          onPressed: acting || !controller.canAct ? null : () => _review(run),
          child: const Text('Let’s keep going!'),
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: acting || !controller.canAct
            ? null
            : () => _act(controller.finishRecall),
        child: const Text('Finish for now'),
      ),
      const SizedBox(height: 20),
      Text(
        'Review your answers',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      for (final question in run.quiz!.questions)
        Card(
          child: ExpansionTile(
            key: PageStorageKey('recall-result-${run.id}-${question.id}'),
            title: Text(question.concept),
            subtitle: Text(
              '${(question.points(run.answers, grades: run.grades) * 100).round()}% of this question',
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final part in question.parts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          '${part.prompt}\nYour answer: ${part.kind == 'choice' ? part.options[run.answers['${question.id}/${part.id}']] ?? 'Unanswered' : run.answers['${question.id}/${part.id}'] ?? 'Unanswered'}\nCorrect answer: ${part.solution}',
                        ),
                      ),
                    Text(question.explanation),
                    const SizedBox(height: 8),
                    Text(
                      question.source,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(question.evidence),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }
}

class RecallHistoryList extends StatelessWidget {
  const RecallHistoryList({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (controller.recallHistory.isNotEmpty) ...[
        const SizedBox(height: 24),
        Text('Recall attempts', style: Theme.of(context).textTheme.titleLarge),
      ],
      for (final run in controller.recallHistory.reversed)
        Card(
          child: ExpansionTile(
            key: PageStorageKey('recall-history-${run.id}'),
            title: Text(run.tasks.map((t) => t['title']).join(', ')),
            subtitle: Text(
              run.stage == 'submitted'
                  ? '${run.quiz!.score(run.answers, grades: run.grades).round()}% · ${run.quiz!.simulated ? 'Simulated demo' : 'Generated quiz'}'
                  : run.stage,
            ),
            children: [
              if (run.quiz != null && run.stage == 'submitted')
                for (final q in run.quiz!.questions)
                  ListTile(
                    title: Text(q.concept),
                    subtitle: Text(
                      '${q.explanation}\n${q.source}\n${q.evidence}',
                    ),
                  ),
              if (controller.recallRun?.id != run.id)
                TextButton(
                  onPressed: () async {
                    final remove = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Delete recall attempt?'),
                        content: const Text(
                          'Remove this quiz attempt. Study time stays saved.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    );
                    if (remove == true) {
                      try {
                        await controller.deleteRecallRun(run.id);
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Could not delete this quiz attempt. Try again.',
                              ),
                            ),
                          );
                        }
                      }
                    }
                  },
                  child: const Text('Delete quiz attempt'),
                ),
            ],
          ),
        ),
    ],
  );
}
