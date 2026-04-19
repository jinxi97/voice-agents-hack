import 'package:flutter/foundation.dart';

enum ArtifactKind { interactiveBook }
enum ArtifactStatus { generating, ready, failed }

class Artifact {
  final String id;
  final ArtifactKind kind;
  final DateTime createdAt;
  ArtifactStatus status;
  String? htmlContent;
  String? error;
  int chunksReceived;
  String partialText;

  Artifact({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.status = ArtifactStatus.generating,
    this.htmlContent,
    this.error,
    this.chunksReceived = 0,
    this.partialText = '',
  });

  String get displayTitle {
    switch (kind) {
      case ArtifactKind.interactiveBook:
        return 'Interactive book';
    }
  }
}

class ArtifactStore extends ChangeNotifier {
  ArtifactStore._();
  static final ArtifactStore instance = ArtifactStore._();

  final List<Artifact> _artifacts = [];
  List<Artifact> get artifacts => List.unmodifiable(_artifacts);

  Artifact create(ArtifactKind kind) {
    final artifact = Artifact(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      kind: kind,
      createdAt: DateTime.now(),
    );
    _artifacts.insert(0, artifact);
    notifyListeners();
    return artifact;
  }

  void touch() => notifyListeners();

  void remove(String id) {
    _artifacts.removeWhere((a) => a.id == id);
    notifyListeners();
  }
}
