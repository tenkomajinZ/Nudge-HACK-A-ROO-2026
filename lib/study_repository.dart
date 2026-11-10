import 'models.dart';

abstract class StudyRepository {
  Future<StoredState> load();
  Future<Subject> addSubject(String name, Priority priority);
  Future<void> updateSubject(Subject subject);
  Future<void> deleteSubject(int id, {required WorkspaceState workspace});
  // Commit workspace changes, study logs, and the active timer atomically.
  Future<void> commit(
    ActiveSession? active,
    List<StudyBlock> newBlocks, {
    WorkspaceState? workspace,
  });
  Future<void> close();
}
