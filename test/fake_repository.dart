import 'package:nudge/models.dart';
import 'package:nudge/study_repository.dart';

class FakeRepository implements StudyRepository {
  List<Subject> subjects = [];
  final Map<String, StudyBlock> savedBlocks = {};
  ActiveSession? active;
  WorkspaceState workspace = const WorkspaceState();
  bool failLoad = false;
  bool failSave = false;
  bool failSubjects = false;
  int commits = 0;
  int _nextId = 1;

  @override
  Future<StoredState> load() async {
    if (failLoad) throw StateError('Disk unavailable');
    return StoredState(
      subjects: List.of(subjects),
      blocks: savedBlocks.values.toList(),
      active: active,
      workspace: workspace,
    );
  }

  @override
  Future<Subject> addSubject(String name, Priority priority) async {
    if (failSubjects) throw StateError('Disk unavailable');
    final created = Subject(id: _nextId++, name: name, priority: priority);
    subjects.add(created);
    return created;
  }

  @override
  Future<void> updateSubject(Subject subject) async {
    if (failSubjects) throw StateError('Disk unavailable');
    subjects = subjects.map((s) => s.id == subject.id ? subject : s).toList();
  }

  @override
  Future<void> deleteSubject(
    int id, {
    required WorkspaceState workspace,
  }) async {
    if (failSave || failSubjects) throw StateError('Disk unavailable');
    subjects = subjects
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
    this.workspace = workspace;
  }

  @override
  Future<void> commit(
    ActiveSession? active,
    List<StudyBlock> newBlocks, {
    WorkspaceState? workspace,
  }) async {
    commits++;
    if (failSave) throw StateError('Disk unavailable');
    for (final block in newBlocks) {
      savedBlocks.putIfAbsent(block.id, () => block);
    }
    this.active = active;
    if (workspace != null) this.workspace = workspace;
  }

  @override
  Future<void> close() async {}
}
