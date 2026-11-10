import 'dart:convert';

import 'package:flutter/services.dart';

import 'recall_models.dart';

class RecallJob {
  const RecallJob(this.id, this.state, {this.quiz, this.error});
  final String id, state;
  final RecallQuiz? quiz;
  final String? error;
}

class RecallGradePart {
  const RecallGradePart({
    required this.question,
    required this.part,
    required this.answer,
  });
  final RecallQuestion question;
  final RecallPart part;
  final String answer;
  String get key => '${question.id}/${part.id}';
}

abstract class RecallGateway {
  Future<Map<String, RecallGrade>> gradeParts(
    String requestId,
    List<RecallGradePart> parts,
  );
  Future<RecallJob> submit(
    RecallMaterial material,
    String requestId,
    List<String> missed, {
    bool retry = false,
    List<String> previous = const [],
  });
  Future<RecallJob> status(String jobId);
  Future<void> delete(String jobId);
}

class SampleRecallGateway implements RecallGateway {
  @override
  Future<Map<String, RecallGrade>> gradeParts(
    String requestId,
    List<RecallGradePart> parts,
  ) async => {
    for (final part in parts)
      part.key: RecallGrade(
        answer: part.answer,
        verdict: 'different',
        source: 'model',
        confidence: 1,
        model: 'deterministic-test',
      ),
  };
  final Map<String, RecallQuiz> _quizzes = {};
  @override
  Future<RecallJob> submit(
    RecallMaterial material,
    String requestId,
    List<String> missed, {
    bool retry = false,
    List<String> previous = const [],
  }) async {
    if (!material.isSample) {
      throw ArgumentError('Choose the bundled sample notes.');
    }
    final json =
        jsonDecode(
              await rootBundle.loadString('assets/recall/sample_quiz.json'),
            )
            as Map<String, dynamic>;
    if (previous.isNotEmpty &&
        (json['questions'] as List).any(
          (q) => previous.contains(
            RecallQuestion.fromJson(
              Map<String, dynamic>.from(q as Map),
            ).wording,
          ),
        )) {
      json['questions'] =
          (jsonDecode(
                await rootBundle.loadString('assets/recall/review_quiz.json'),
              )
              as Map<String, dynamic>)['questions'];
    }
    final questions = List<dynamic>.of(json['questions'] as List);
    // The first demo stays in source order; new attempts rotate to avoid rote order.
    final offset = _quizzes.isEmpty ? 0 : _quizzes.length % questions.length;
    json['questions'] = [...questions.skip(offset), ...questions.take(offset)]
      ..sort(
        (a, b) => (missed.contains((a as Map)['concept']) ? 0 : 1).compareTo(
          missed.contains((b as Map)['concept']) ? 0 : 1,
        ),
      );
    final quiz = RecallQuiz.fromJson(json);
    _quizzes[requestId] = quiz;
    return RecallJob(requestId, 'ready', quiz: quiz);
  }

  @override
  Future<RecallJob> status(String jobId) async => _quizzes[jobId] == null
      ? RecallJob(
          jobId,
          'failed',
          error: 'Saved sample was cleared. Retry to load it again.',
        )
      : RecallJob(jobId, 'ready', quiz: _quizzes[jobId]);
  @override
  Future<void> delete(String jobId) async {
    _quizzes.remove(jobId);
  }
}
