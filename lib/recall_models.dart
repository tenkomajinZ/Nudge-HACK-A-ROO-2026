// Recall state lives alongside the timer; timer phase ordinals never change.
class RecallMaterial {
  const RecallMaterial({
    required this.path,
    required this.name,
    this.consent = false,
    this.live = false,
  });
  static const sample = RecallMaterial(
    path: 'sample',
    name: 'Demonstration notes',
    consent: true,
  );
  final String path, name;
  final bool consent, live;
  bool get isSample => path == 'sample';
  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'consent': consent,
    'live': live,
  };
  factory RecallMaterial.fromJson(Map<String, dynamic> j) => RecallMaterial(
    path: j['path'] as String,
    name: j['name'] as String,
    consent: j['consent'] == true,
    live: j['live'] == true,
  );
}

String normalizeRecall(String text) =>
    text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
String recallTier(double score) => score >= 100
    ? 'perfect'
    : score >= 70
    ? 'veryGood'
    : score >= 50
    ? 'almost'
    : 'review';

class RecallGrade {
  static const equivalenceCutoffPercent = 45;

  const RecallGrade({
    required this.answer,
    required this.verdict,
    required this.source,
    this.confidence,
    this.model,
  });
  final String answer, verdict, source;
  final double? confidence;
  final String? model;
  bool get earnsCredit =>
      verdict == 'equivalent' &&
      (source != 'model' ||
          (confidence ?? 0) >= equivalenceCutoffPercent / 100);
  RecallGrade get automatic => source != 'model'
      ? this
      : RecallGrade(
          answer: answer,
          verdict: earnsCredit ? 'equivalent' : 'different',
          source: source,
          confidence: confidence,
          model: model,
        );
  bool get resolved =>
      ['equivalent', 'different', 'incomplete'].contains(verdict);
  bool appliesTo(String? value) => answer == value;
  Map<String, dynamic> toJson() => {
    'answer': answer,
    'verdict': verdict,
    'source': source,
    'confidence': confidence,
    'model': model,
  };
  factory RecallGrade.fromJson(Map<String, dynamic> j) {
    final verdict = j['verdict'] as String;
    final source = j['source'] as String;
    final confidence = (j['confidence'] as num?)?.toDouble();
    if (![
          'equivalent',
          'different',
          'incomplete',
          'uncertain',
        ].contains(verdict) ||
        !['model', 'self', 'unavailable'].contains(source) ||
        (confidence != null &&
            (!confidence.isFinite || confidence < 0 || confidence > 1))) {
      throw const FormatException('Invalid saved recall grade');
    }
    return RecallGrade(
      answer: j['answer'] as String,
      verdict: verdict,
      source: source,
      confidence: confidence,
      model: j['model'] as String?,
    ).automatic;
  }
}

class RecallPart {
  RecallPart.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      prompt = j['prompt'] as String,
      kind = j['kind'] as String,
      options = Map<String, String>.from(j['options'] as Map),
      correct = j['correct'] as String,
      accepted = List<String>.from(j['accepted'] as List) {
    if (id.isEmpty ||
        prompt.isEmpty ||
        !['choice', 'fill'].contains(kind) ||
        (kind == 'choice' &&
            (options.length < 2 || !options.containsKey(correct))) ||
        (kind == 'fill' &&
            (accepted.isEmpty || accepted.any((a) => a.trim().isEmpty)))) {
      throw const FormatException('Invalid question answer');
    }
  }
  final String id, prompt, kind, correct;
  final Map<String, String> options;
  final List<String> accepted;
  bool accepts(String? answer) =>
      answer != null &&
      (kind == 'choice'
          ? answer == correct
          : accepted.any((a) => normalizeRecall(a) == normalizeRecall(answer)));
  bool isCorrect(String? answer, [RecallGrade? grade]) =>
      accepts(answer) ||
      (kind == 'fill' &&
          (answer ?? '').trim().isNotEmpty &&
          grade?.appliesTo(answer) == true &&
          grade!.earnsCredit);
  bool needsGrade(String? answer, [RecallGrade? grade]) =>
      kind == 'fill' &&
      (answer ?? '').trim().isNotEmpty &&
      !accepts(answer) &&
      !(grade?.appliesTo(answer) == true && grade!.resolved);
  String get solution => kind == 'choice' ? options[correct]! : accepted.first;
  Map<String, dynamic> toJson() => {
    'id': id,
    'prompt': prompt,
    'kind': kind,
    'options': options,
    'correct': correct,
    'accepted': accepted,
  };
}

class RecallQuestion {
  RecallQuestion.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      concept = j['concept'] as String,
      prompt = j['prompt'] as String,
      source = j['source'] as String,
      evidence = j['evidence'] as String,
      explanation = j['explanation'] as String,
      parts = (j['parts'] as List)
          .map((p) => RecallPart.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList() {
    if ([
          id,
          concept,
          prompt,
          source,
          evidence,
          explanation,
        ].any((s) => s.trim().isEmpty) ||
        parts.isEmpty ||
        parts.length > 4 ||
        parts.map((p) => p.id).toSet().length != parts.length) {
      throw const FormatException('Invalid question or source');
    }
  }
  String get wording => '$prompt | ${parts.map((p) => p.prompt).join(' | ')}';
  final String id, concept, prompt, source, evidence, explanation;
  final List<RecallPart> parts;
  double points(
    Map<String, String> answers, {
    Map<String, RecallGrade> grades = const {},
  }) =>
      parts
          .where(
            (p) => p.isCorrect(answers['$id/${p.id}'], grades['$id/${p.id}']),
          )
          .length /
      parts.length;
  bool isAnswered(Map<String, String> answers) => parts.every((p) {
    final answer = answers['$id/${p.id}'] ?? '';
    return answer.trim().isNotEmpty &&
        (p.kind != 'choice' || p.options.containsKey(answer));
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'concept': concept,
    'prompt': prompt,
    'source': source,
    'evidence': evidence,
    'explanation': explanation,
    'parts': parts.map((p) => p.toJson()).toList(),
  };
}

class RecallQuiz {
  RecallQuiz({required this.simulated, required this.questions}) {
    if (questions.length != 10 ||
        questions.map((q) => q.id).toSet().length != 10) {
      throw const FormatException(
        'A supported quiz needs ten distinct questions',
      );
    }
    final wordings = questions.map((q) => normalizeRecall(q.wording)).toSet();
    final kinds = questions.expand((q) => q.parts.map((p) => p.kind)).toSet();
    if (wordings.length != 10 ||
        !kinds.containsAll(['choice', 'fill']) ||
        !questions.any((q) => q.parts.length > 1)) {
      throw const FormatException(
        'Use distinct questions with choices, fill-ins, and multipart questions.',
      );
    }
  }
  factory RecallQuiz.fromJson(Map<String, dynamic> j) => RecallQuiz(
    simulated: j['simulated'] == true,
    questions: (j['questions'] as List)
        .map(
          (q) => RecallQuestion.fromJson(Map<String, dynamic>.from(q as Map)),
        )
        .toList(),
  );
  final bool simulated;
  final List<RecallQuestion> questions;
  double score(
    Map<String, String> answers, {
    Map<String, RecallGrade> grades = const {},
  }) {
    // 12 is divisible by every supported part count (1–4). Keep partial
    // credit integral until division so exact score bands stay exact.
    final units = questions.fold<int>(
      0,
      (total, q) =>
          total +
          q.parts
                  .where(
                    (p) => p.isCorrect(
                      answers['${q.id}/${p.id}'],
                      grades['${q.id}/${p.id}'],
                    ),
                  )
                  .length *
              (12 ~/ q.parts.length),
    );
    return units * 100 / (questions.length * 12);
  }

  List<String> missed(
    Map<String, String> answers, {
    Map<String, RecallGrade> grades = const {},
  }) => questions
      .where((q) => q.points(answers, grades: grades) < 1)
      .map((q) => q.concept)
      .toSet()
      .toList();
  Map<String, dynamic> toJson() => {
    'simulated': simulated,
    'questions': questions.map((q) => q.toJson()).toList(),
  };
}

class RecallEntry {
  const RecallEntry({
    required this.taskId,
    required this.requestId,
    this.jobId,
    this.state = 'selected',
    this.quiz,
    this.error,
  });
  final String taskId, requestId, state;
  final String? jobId, error;
  final RecallQuiz? quiz;
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'requestId': requestId,
    'jobId': jobId,
    'state': state,
    'quiz': quiz?.toJson(),
    'error': error,
  };
  factory RecallEntry.fromJson(Map<String, dynamic> j) => RecallEntry(
    taskId: j['taskId'] as String,
    requestId: j['requestId'] as String,
    jobId: j['jobId'] as String?,
    state: j['state'] as String,
    quiz: j['quiz'] == null
        ? null
        : RecallQuiz.fromJson(Map<String, dynamic>.from(j['quiz'] as Map)),
    error: j['error'] as String?,
  );
}

class RecallRun {
  const RecallRun({
    required this.id,
    required this.tasks,
    this.stage = 'studying',
    this.entries = const [],
    this.quiz,
    this.answers = const {},
    this.grades = const {},
    this.gradingMode = 'legacy',
    this.currentQuestionIndex = 0,
    this.checkedQuestionIds = const {},
    this.missed = const [],
    this.previous = const [],
  });
  final String id, stage;
  // Immutable JSON task snapshots remain after queue removal.
  final List<Map<String, dynamic>> tasks;
  final List<RecallEntry> entries;
  final RecallQuiz? quiz;
  final Map<String, String> answers;
  final Map<String, RecallGrade> grades;
  final String gradingMode;
  List<String> get unresolvedKeys => gradingMode != 'laya'
      ? const []
      : [
          for (final q in quiz?.questions ?? <RecallQuestion>[])
            for (final p in q.parts)
              if (p.needsGrade(
                answers['${q.id}/${p.id}'],
                grades['${q.id}/${p.id}'],
              ))
                '${q.id}/${p.id}',
        ];
  final int currentQuestionIndex;
  final Set<String> checkedQuestionIds;
  bool get answerChecked => checkedQuestionIds.contains(currentQuestion?.id);
  int get incompleteCount =>
      quiz?.questions.where((q) => !q.isAnswered(answers)).length ?? 0;
  RecallQuestion? get currentQuestion =>
      quiz != null &&
          currentQuestionIndex >= 0 &&
          currentQuestionIndex < quiz!.questions.length
      ? quiz!.questions[currentQuestionIndex]
      : null;
  final List<String> missed, previous;
  RecallRun copyWith({
    String? stage,
    List<RecallEntry>? entries,
    RecallQuiz? quiz,
    Map<String, String>? answers,
    Map<String, RecallGrade>? grades,
    int? currentQuestionIndex,
    Set<String>? checkedQuestionIds,
  }) => RecallRun(
    id: id,
    tasks: tasks,
    stage: stage ?? this.stage,
    entries: entries ?? this.entries,
    quiz: quiz ?? this.quiz,
    answers: answers ?? this.answers,
    grades: grades ?? this.grades,
    gradingMode: gradingMode,
    currentQuestionIndex: currentQuestionIndex ?? this.currentQuestionIndex,
    checkedQuestionIds: checkedQuestionIds ?? this.checkedQuestionIds,
    missed: missed,
    previous: previous,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'tasks': tasks,
    'stage': stage,
    'entries': entries.map((e) => e.toJson()).toList(),
    'quiz': quiz?.toJson(),
    'answers': answers,
    'grades': grades.map((key, value) => MapEntry(key, value.toJson())),
    'gradingMode': gradingMode,
    'currentQuestionIndex': currentQuestionIndex,
    'answerChecked': answerChecked,
    'checkedQuestionIds': checkedQuestionIds.toList(),
    'missed': missed,
    'previous': previous,
  };
  factory RecallRun.fromJson(Map<String, dynamic> j) {
    final quiz = j['quiz'] == null
        ? null
        : RecallQuiz.fromJson(Map<String, dynamic>.from(j['quiz'] as Map));
    final answers = Map<String, String>.from(j['answers'] as Map);
    final index = j['currentQuestionIndex'] as int? ?? 0;
    final checked = j['checkedQuestionIds'] is List
        ? Set<String>.from(j['checkedQuestionIds'] as List)
        : <String>{
            for (var i = 0; i < (quiz?.questions.length ?? 0); i++)
              if ((i < index && quiz!.questions[i].isAnswered(answers)) ||
                  (i == index && j['answerChecked'] == true))
                quiz!.questions[i].id,
          };
    final rawGrades = Map<String, dynamic>.from(
      j['grades'] as Map? ?? const {},
    );
    final grades = rawGrades.map(
      (key, value) => MapEntry(
        key,
        RecallGrade.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    );
    // Saved model uncertainty becomes an automatic incorrect answer under the new policy.
    if (j['gradingMode'] == 'laya' && j['stage'] == 'answering') {
      for (final q in quiz?.questions ?? <RecallQuestion>[]) {
        if (q.isAnswered(answers) &&
            q.parts.any(
              (p) =>
                  (rawGrades['${q.id}/${p.id}'] as Map?)?['verdict'] ==
                      'uncertain' &&
                  grades['${q.id}/${p.id}']?.source == 'model',
            ) &&
            q.parts.every(
              (p) => !p.needsGrade(
                answers['${q.id}/${p.id}'],
                grades['${q.id}/${p.id}'],
              ),
            )) {
          checked.add(q.id);
        }
      }
    }
    return RecallRun(
      id: j['id'] as String,
      tasks: (j['tasks'] as List)
          .map((t) => Map<String, dynamic>.from(t as Map))
          .toList(),
      stage: j['stage'] as String,
      entries: (j['entries'] as List)
          .map((e) => RecallEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      quiz: quiz,
      answers: answers,
      grades: grades,
      gradingMode: j['gradingMode'] as String? ?? 'legacy',
      currentQuestionIndex: index,
      checkedQuestionIds: checked,
      missed: List<String>.from(j['missed'] as List),
      previous: List<String>.from(j['previous'] as List? ?? const []),
    );
  }
}

class RecallState {
  const RecallState({this.runs = const [], this.currentId});
  final List<RecallRun> runs;
  final String? currentId;
  RecallRun? get current => runs.where((r) => r.id == currentId).firstOrNull;
  RecallState update(RecallRun run) => RecallState(
    currentId: run.id,
    runs: [...runs.where((r) => r.id != run.id), run],
  );
  Map<String, dynamic> toJson() => {
    'runs': runs.map((r) => r.toJson()).toList(),
    'currentId': currentId,
  };
  factory RecallState.fromJson(Map<String, dynamic> j) => RecallState(
    currentId: j['currentId'] as String?,
    runs: (j['runs'] as List)
        .map((r) => RecallRun.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList(),
  );
}
