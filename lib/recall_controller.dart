part of 'session_controller.dart';

extension RecallActions on SessionController {
  Future<RecallJob> _submitRecallMaterial(
    RecallMaterial material,
    String requestId,
    List<String> missed, {
    bool retry = false,
    List<String> previous = const [],
  }) {
    return recallGateway.submit(
      material,
      requestId,
      missed,
      retry: retry,
      previous: previous,
    );
  }

  RecallRun? get recallRun => _workspace.recall.current;
  List<RecallRun> get recallHistory =>
      List.unmodifiable(_workspace.recall.runs);
  bool get _hasRecallFocus {
    final run = recallRun;
    return run != null &&
        run.tasks.any(
          (t) =>
              t['material'] != null &&
              _blocks.any(
                (b) =>
                    b.runId == run.id &&
                    b.taskId == t['id'] &&
                    b.focusSeconds > 0,
              ),
        );
  }

  List<FocusTask> _studiedRecallTasks(RecallRun run) => run.tasks
      .map(FocusTask.fromJson)
      .where(
        (task) =>
            task.material != null &&
            _blocks.any(
              (b) =>
                  b.runId == run.id &&
                  b.taskId == task.id &&
                  b.focusSeconds > 0,
            ),
      )
      .toList();

  void _setRecallRun(RecallRun run) {
    _workspace = WorkspaceState(
      settings: settings,
      queue: queue,
      recall: _workspace.recall.update(run),
    );
  }

  void _beginRecallRun(
    List<FocusTask> tasks, {
    List<String> missed = const [],
    List<String> previous = const [],
  }) {
    if (!tasks.any((t) => t.material != null)) return;
    final runId =
        'run-${now.microsecondsSinceEpoch}-${_workspace.recall.runs.length}';
    _setRecallRun(
      RecallRun(
        id: runId,
        gradingMode: 'demo',
        tasks: tasks.map((t) => Map<String, dynamic>.from(t.toJson())).toList(),
        missed: missed,
        previous: previous,
        entries: tasks
            .where((t) => t.material != null)
            .map(
              (t) => RecallEntry(
                taskId: t.id,
                requestId: '$runId-${tasks.indexOf(t)}',
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> _recallChange(bool Function() change) async {
    while (busy && !_disposed) {
      await (_idleWaiter ??= Completer<void>()).future;
    }
    if (_disposed) return;
    await _change(change, reconcileDevices: false);
  }

  Future<void> pollRecall() async {
    final run = recallRun;
    if (run == null ||
        _recallNetworkBusy ||
        !canAct ||
        !['studying', 'choice'].contains(run.stage)) {
      return;
    }
    final eligible = _studiedRecallTasks(run).map((t) => t.id).toSet();
    if (active?.task?.material != null) eligible.add(active!.task!.id);
    final entry = run.entries
        .where(
          (e) =>
              eligible.contains(e.taskId) &&
              ['selected', 'uploading', 'preparing'].contains(e.state),
        )
        .firstOrNull;
    if (entry == null) return;
    _recallNetworkBusy = true;
    try {
      final task = run.tasks
          .map(FocusTask.fromJson)
          .firstWhere((t) => t.id == entry.taskId);
      final result = entry.jobId == null
          ? await _submitRecallMaterial(
              task.material!,
              entry.requestId,
              run.missed,
              previous: run.previous,
            )
          : await recallGateway.status(entry.jobId!);
      await _recallChange(() {
        if (recallRun?.id != run.id ||
            !recallRun!.entries.any((e) => e.requestId == entry.requestId)) {
          return false;
        }
        _setRecallRun(
          recallRun!.copyWith(
            entries: [
              for (final e in recallRun!.entries)
                e.requestId == entry.requestId
                    ? RecallEntry(
                        taskId: e.taskId,
                        requestId: e.requestId,
                        jobId: result.id,
                        state: result.state,
                        quiz: result.quiz,
                        error: result.error,
                      )
                    : e,
            ],
          ),
        );
        return true;
      });
    } catch (error) {
      await _recallChange(() {
        if (recallRun?.id != run.id) return false;
        _setRecallRun(
          recallRun!.copyWith(
            entries: [
              for (final e in recallRun!.entries)
                e.requestId == entry.requestId
                    ? RecallEntry(
                        taskId: e.taskId,
                        requestId: e.requestId,
                        jobId: e.jobId,
                        state: 'failed',
                        error:
                            'Could not prepare recall. ${error.toString().replaceFirst('Bad state: ', '')}',
                      )
                    : e,
            ],
          ),
        );
        return true;
      });
    } finally {
      _recallNetworkBusy = false;
    }
  }

  Future<void> retryRecall() async {
    final run = recallRun;
    if (run == null || _recallNetworkBusy) return;
    _recallNetworkBusy = true;
    try {
      for (final entry in run.entries.where((e) => e.state == 'failed')) {
        final task = run.tasks
            .map(FocusTask.fromJson)
            .firstWhere((t) => t.id == entry.taskId);
        try {
          final result = await _submitRecallMaterial(
            task.material!,
            entry.requestId,
            run.missed,
            retry: true,
            previous: run.previous,
          );
          await _recallChange(() {
            if (recallRun?.id != run.id) return false;
            _setRecallRun(
              recallRun!.copyWith(
                entries: [
                  for (final e in recallRun!.entries)
                    e.requestId == entry.requestId
                        ? RecallEntry(
                            taskId: e.taskId,
                            requestId: e.requestId,
                            jobId: result.id,
                            state: result.state,
                            quiz: result.quiz,
                            error: result.error,
                          )
                        : e,
                ],
              ),
            );
            return true;
          });
        } catch (error) {
          await _recallChange(() {
            if (recallRun?.id != run.id) return false;
            _setRecallRun(
              recallRun!.copyWith(
                entries: [
                  for (final e in recallRun!.entries)
                    e.requestId == entry.requestId
                        ? RecallEntry(
                            taskId: e.taskId,
                            requestId: e.requestId,
                            jobId: e.jobId,
                            state: 'failed',
                            error:
                                'Could not prepare recall. ${error.toString().replaceFirst('Bad state: ', '')}',
                          )
                        : e,
                ],
              ),
            );
            return true;
          });
        }
      }
    } finally {
      _recallNetworkBusy = false;
      _notify();
    }
  }

  bool get recallReady {
    final run = recallRun;
    if (run == null) return false;
    final tasks = _studiedRecallTasks(run);
    return tasks.isNotEmpty &&
        tasks.every(
          (t) => run.entries.any((e) => e.taskId == t.id && e.quiz != null),
        );
  }

  Future<void> startRecall() async {
    if (!recallReady || recallRun?.stage != 'choice') return;
    final run = recallRun!;
    final tasks = _studiedRecallTasks(run);
    final entries = run.entries
        .where((e) => tasks.any((t) => t.id == e.taskId))
        .toList();
    final questions = <RecallQuestion>[];
    if (entries.length == 1) {
      questions.addAll(entries.single.quiz!.questions);
    } else {
      final banks = [
        for (final entry in entries)
          [
            for (final q in entry.quiz!.questions)
              RecallQuestion.fromJson({
                ...q.toJson(),
                'id': '${entry.taskId}-${q.id}',
                'source':
                    '${tasks.firstWhere((t) => t.id == entry.taskId).material!.name} · ${q.source}',
              }),
          ],
      ];
      final used = <String>{};
      final covered = <String>{};
      Set<String> categories(RecallQuestion q) => {
        ...q.parts.map((p) => p.kind),
        if (q.parts.length > 1) 'multipart',
      };
      bool addFrom(List<RecallQuestion> bank) {
        final options = bank
            .where((q) => !used.contains(normalizeRecall(q.wording)))
            .toList();
        if (options.isEmpty) return false;
        options.sort(
          (a, b) => categories(b)
              .difference(covered)
              .length
              .compareTo(categories(a).difference(covered).length),
        );
        final selected = options.first;
        used.add(normalizeRecall(selected.wording));
        covered.addAll(categories(selected));
        questions.add(selected);
        return true;
      }

      // Represent materials first, prioritizing missing formats; then fill distinct questions fairly.
      for (final bank in banks) {
        if (questions.length < 10) addFrom(bank);
      }
      while (questions.length < 10) {
        var added = false;
        for (final bank in banks) {
          if (questions.length < 10) added = addFrom(bank) || added;
        }
        if (!added) {
          throw const FormatException(
            'Not enough distinct supported questions.',
          );
        }
      }
    }
    await _change(() {
      _active = null;
      _setRecallRun(
        run.copyWith(
          stage: 'answering',
          quiz: RecallQuiz(
            simulated: entries.any((e) => e.quiz!.simulated),
            questions: questions,
          ),
        ),
      );
      return true;
    });
  }

  Future<void> setRecallAnswer(String key, String value) => _recallChange(() {
    final run = recallRun;
    if (run == null || run.stage != 'answering' || run.answerChecked) {
      return false;
    }
    final question = run.currentQuestion;
    final part = question?.parts
        .where((p) => '${question.id}/${p.id}' == key)
        .firstOrNull;
    if (part == null ||
        (part.kind == 'choice' && !part.options.containsKey(value))) {
      return false;
    }
    final grades = Map<String, RecallGrade>.from(run.grades)..remove(key);
    _setRecallRun(
      run.copyWith(answers: {...run.answers, key: value}, grades: grades),
    );
    return true;
  });
  Future<void> checkRecallAnswer(String questionId) async {
    final run = recallRun;
    if (run == null ||
        _recallGradingBusy ||
        run.stage != 'answering' ||
        run.answerChecked ||
        run.currentQuestion?.id != questionId ||
        !run.currentQuestion!.isAnswered(run.answers)) {
      return;
    }
    await _resolveRecallGrades(run, [
      run.currentQuestion!,
    ], checkedQuestionId: questionId);
  }

  Future<void> retryRecallGrading(String questionId) async {
    final run = recallRun;
    if (run == null ||
        _recallGradingBusy ||
        run.stage != 'answering' ||
        run.currentQuestion?.id != questionId) {
      return;
    }
    await _resolveRecallGrades(
      run,
      [run.currentQuestion!],
      checkedQuestionId: questionId,
      retry: true,
    );
  }

  Future<void> _resolveRecallGrades(
    RecallRun snapshot,
    List<RecallQuestion> questions, {
    String? checkedQuestionId,
    bool retry = false,
    bool submit = false,
  }) async {
    if (_recallGradingBusy) return;
    _recallGradingBusy = true;
    recallGradingMessage = null;
    final serial = ++_recallGradeSerial;
    final parts = <RecallGradePart>[
      if (snapshot.gradingMode == 'laya')
        for (final q in questions)
          for (final p in q.parts)
            if (p.needsGrade(
                  snapshot.answers['${q.id}/${p.id}'],
                  snapshot.grades['${q.id}/${p.id}'],
                ) &&
                (retry ||
                    snapshot.grades['${q.id}/${p.id}']?.appliesTo(
                          snapshot.answers['${q.id}/${p.id}'],
                        ) !=
                        true))
              RecallGradePart(
                question: q,
                part: p,
                answer: snapshot.answers['${q.id}/${p.id}']!,
              ),
    ];
    _notify();
    var grades = <String, RecallGrade>{};
    String? failure;
    try {
      if (parts.isNotEmpty) {
        grades = await recallGateway.gradeParts(
          'grade-$serial-${now.microsecondsSinceEpoch}',
          parts,
        );
        // Gateways and test fakes share the same identity/answer contract.
        if (grades.length != parts.length ||
            parts.any((p) => grades[p.key]?.appliesTo(p.answer) != true)) {
          throw const FormatException(
            'Grading response did not match these answers',
          );
        }
      }
    } catch (error) {
      failure = error.toString().replaceFirst('Bad state: ', '');
      grades = {
        for (final p in parts)
          p.key: RecallGrade(
            answer: p.answer,
            verdict: 'uncertain',
            source: 'unavailable',
          ),
      };
    }
    try {
      await _recallChange(() {
        final current = recallRun;
        if (_disposed ||
            current == null ||
            current.id != snapshot.id ||
            current.stage != 'answering' ||
            !identical(current.quiz, snapshot.quiz) ||
            (checkedQuestionId != null &&
                current.currentQuestion?.id != checkedQuestionId) ||
            (submit && !mapEquals(current.answers, snapshot.answers)) ||
            questions.any(
              (q) => q.parts.any(
                (p) =>
                    current.answers['${q.id}/${p.id}'] !=
                    snapshot.answers['${q.id}/${p.id}'],
              ),
            )) {
          return false;
        }
        var updated = current.copyWith(
          grades: {
            ...current.grades,
            ...grades.map((key, value) => MapEntry(key, value.automatic)),
          },
        );
        if (checkedQuestionId != null &&
            !updated.unresolvedKeys.any(
              (key) => key.startsWith('$checkedQuestionId/'),
            )) {
          updated = updated.copyWith(
            checkedQuestionIds: {
              ...updated.checkedQuestionIds,
              checkedQuestionId,
            },
          );
        }
        if (submit) {
          if (updated.unresolvedKeys.isEmpty) {
            updated = updated.copyWith(stage: 'submitted');
          } else {
            final firstKey = updated.unresolvedKeys.first;
            updated = updated.copyWith(
              currentQuestionIndex: updated.quiz!.questions.indexWhere(
                (q) => q.parts.any((p) => '${q.id}/${p.id}' == firstKey),
              ),
            );
          }
        }
        recallGradingMessage =
            failure ??
            (updated.unresolvedKeys.isNotEmpty && submit
                ? 'Some answers could not be checked. Retry grading before submitting.'
                : null);
        _setRecallRun(updated);
        return true;
      });
    } finally {
      _recallGradingBusy = false;
      _notify();
    }
  }

  Future<void> goToRecallQuestion(
    String questionId, {
    required String fromQuestionId,
  }) {
    final runId = recallRun?.id;
    return _recallChange(() {
      final run = recallRun;
      if (run == null ||
          run.id != runId ||
          run.stage != 'answering' ||
          run.currentQuestion?.id != fromQuestionId) {
        return false;
      }
      final index = run.quiz!.questions.indexWhere((q) => q.id == questionId);
      if (index < 0 || index == run.currentQuestionIndex) return false;
      _setRecallRun(run.copyWith(currentQuestionIndex: index));
      return true;
    });
  }

  Future<void> nextRecallQuestion(String questionId) {
    final run = recallRun;
    if (run == null ||
        run.currentQuestion?.id != questionId ||
        run.currentQuestionIndex >= run.quiz!.questions.length - 1) {
      return Future.value();
    }
    return goToRecallQuestion(
      run.quiz!.questions[run.currentQuestionIndex + 1].id,
      fromQuestionId: questionId,
    );
  }

  Future<void> submitRecall({
    required String runId,
    bool allowIncomplete = false,
  }) async {
    final run = recallRun;
    if (run == null ||
        run.id != runId ||
        _recallGradingBusy ||
        run.stage != 'answering' ||
        (!allowIncomplete && run.incompleteCount > 0)) {
      return;
    }
    await _resolveRecallGrades(run, run.quiz!.questions, submit: true);
  }

  Future<void> keepStudying() async {
    if (recallRun?.stage != 'choice') return;
    if (_active?.phase == SessionPhase.rest) {
      await returnToStudy();
      return;
    }
    await _change(() {
      final run = recallRun!;
      final last = _studiedRecallTasks(run).last;
      _setRecallRun(run.copyWith(stage: 'studying'));
      _active = ActiveSession(
        blockId: _blockId(last.subjectId),
        subjectId: last.subjectId,
        phase: SessionPhase.preparing,
        startedAt: now,
        endsAt: now.add(const Duration(seconds: 30)),
        tasks: [last],
        autoRepeat: true,
      );
      return true;
    });
  }

  Future<void> studyAgain(int minutes) async {
    if (recallRun?.stage != 'submitted') return;
    if (minutes < 1 || minutes > 180) {
      throw ArgumentError('Choose 1–180 minutes.');
    }
    await _change(() {
      final old = recallRun!;
      final tasks = _studiedRecallTasks(old)
          .map(
            (t) => FocusTask(
              id: 'review-${now.microsecondsSinceEpoch}-${t.id}',
              subjectId: t.subjectId,
              title: 'Review: ${t.title}',
              config: TimerConfig(
                focusMinutes: minutes,
                breakMinutes: t.config.breakMinutes,
              ),
              material: t.material,
            ),
          )
          .toList();
      _beginRecallRun(
        tasks,
        missed: old.quiz!.missed(old.answers, grades: old.grades),
        previous: old.quiz!.questions.map((q) => q.wording).toList(),
      );
      final first = tasks.first;
      _active = ActiveSession(
        blockId: _blockId(first.subjectId),
        subjectId: first.subjectId,
        phase: SessionPhase.preparing,
        startedAt: now,
        endsAt: now.add(const Duration(seconds: 30)),
        tasks: tasks,
        autoRepeat: true,
      );
      return true;
    });
  }

  Future<void> finishRecall() => _change(() {
    _active = null;
    final run = recallRun;
    if (run != null) {
      final state = _workspace.recall.update(
        run.stage == 'submitted' ? run : run.copyWith(stage: 'finished'),
      );
      _workspace = WorkspaceState(
        settings: settings,
        queue: queue,
        recall: RecallState(runs: state.runs),
      );
    }
    return true;
  });

  Future<void> deleteRecallRun(String id) async {
    final run = recallHistory.where((r) => r.id == id).firstOrNull;
    if (run == null || recallRun?.id == id) return;
    for (final entry in run.entries) {
      final task = run.tasks
          .map(FocusTask.fromJson)
          .firstWhere((t) => t.id == entry.taskId);
      if (task.material?.isSample == true) continue;
      if (entry.jobId != null) await recallGateway.delete(entry.jobId!);
    }
    await _recallChange(() {
      _workspace = WorkspaceState(
        settings: settings,
        queue: queue,
        recall: RecallState(
          currentId: _workspace.recall.currentId,
          runs: _workspace.recall.runs.where((r) => r.id != id).toList(),
        ),
      );
      return true;
    });
  }
}
