import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'cactus_service.dart';

class TranscriptLine {
  final bool isMe;
  final String text;
  final DateTime timestamp;
  TranscriptLine({
    required this.isMe,
    required this.text,
    required this.timestamp,
  });
}

class SavedCall {
  final DateTime startedAt;
  final String slug;
  final File myWav;
  final File otherWav;
  final File? myTranscript;
  final File? otherTranscript;
  final File? conversation;
  final File? story;

  const SavedCall({
    required this.startedAt,
    required this.slug,
    required this.myWav,
    required this.otherWav,
    this.myTranscript,
    this.otherTranscript,
    this.conversation,
    this.story,
  });

  SavedCall copyWith({File? story}) => SavedCall(
        startedAt: startedAt,
        slug: slug,
        myWav: myWav,
        otherWav: otherWav,
        myTranscript: myTranscript,
        otherTranscript: otherTranscript,
        conversation: conversation,
        story: story ?? this.story,
      );
}

class CallTranscriber extends ChangeNotifier {
  CallTranscriber._();
  static final CallTranscriber instance = CallTranscriber._();

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bitsPerSample = 16;
  static const Duration flushInterval = Duration(seconds: 8);
  static const String callsDirName = 'calls';
  // Skip chunks with fewer samples than this (less than ~0.5s of audio).
  static const int minBytesToTranscribe = sampleRate * 2 ~/ 2;

  /// Streaming transcript lines (used for live captions; not displayed in
  /// the Debug tab).
  final List<TranscriptLine> _lines = [];
  List<TranscriptLine> get lines => List.unmodifiable(_lines);

  // Streaming buffers — drained every [flushInterval] for live captions.
  final BytesBuilder _myStreamBuf = BytesBuilder(copy: true);
  final BytesBuilder _otherStreamBuf = BytesBuilder(copy: true);

  // Full-call buffers — preserved for the entire call and persisted on stop.
  final BytesBuilder _myFullBuf = BytesBuilder(copy: true);
  final BytesBuilder _otherFullBuf = BytesBuilder(copy: true);

  DateTime? _callStartedAt;
  // Wall-clock arrival of the first audio frame from each speaker. Used to
  // align per-file timestamps onto a shared call timeline when interleaving
  // the conversation.
  DateTime? _myFirstFrameAt;
  DateTime? _otherFirstFrameAt;

  Timer? _timer;
  bool _busy = false;
  bool _active = false;
  String? _status;
  String? _error;

  String? get status => _status;
  String? get error => _error;
  bool get isActive => _active;

  Future<void> start() async {
    if (_active) return;
    _active = true;
    _error = null;
    _status = 'Loading Whisper…';
    _myStreamBuf.clear();
    _otherStreamBuf.clear();
    _myFullBuf.clear();
    _otherFullBuf.clear();
    _callStartedAt = DateTime.now();
    _myFirstFrameAt = null;
    _otherFirstFrameAt = null;
    notifyListeners();

    try {
      await CactusService.instance.initWhisper((_) {});
      _status = 'Listening';
    } catch (e) {
      _error = 'Failed to load Whisper: $e';
      _status = null;
    }
    notifyListeners();

    _timer = Timer.periodic(flushInterval, (_) => _flush());
  }

  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _timer?.cancel();
    _timer = null;
    _status = 'Finalizing…';
    notifyListeners();
    await _flush();
    await _persistAndPostTranscribe();
    _status = null;
    notifyListeners();
  }

  void addMyFrame(Uint8List? bytes) {
    if (!_active || bytes == null || bytes.isEmpty) return;
    _myFirstFrameAt ??= DateTime.now();
    _myStreamBuf.add(bytes);
    _myFullBuf.add(bytes);
  }

  void addOtherFrame(Uint8List? bytes) {
    if (!_active || bytes == null || bytes.isEmpty) return;
    _otherFirstFrameAt ??= DateTime.now();
    _otherStreamBuf.add(bytes);
    _otherFullBuf.add(bytes);
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  Future<void> _flush() async {
    if (_busy) return;
    _busy = true;
    try {
      if (_myStreamBuf.length >= minBytesToTranscribe) {
        final bytes = _myStreamBuf.takeBytes();
        await _transcribeAndAppend(bytes, isMe: true);
      }
      if (_otherStreamBuf.length >= minBytesToTranscribe) {
        final bytes = _otherStreamBuf.takeBytes();
        await _transcribeAndAppend(bytes, isMe: false);
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  Future<void> _transcribeAndAppend(
    Uint8List pcmBytes, {
    required bool isMe,
  }) async {
    final wavBytes = CactusService.buildWav(
      pcmBytes,
      sampleRate,
      channels,
      bitsPerSample,
    );
    final tmp = await getTemporaryDirectory();
    final path =
        '${tmp.path}/call_${isMe ? 'me' : 'other'}_${DateTime.now().microsecondsSinceEpoch}.wav';
    final file = File(path);
    await file.writeAsBytes(wavBytes);
    try {
      final raw = await CactusService.instance.transcribeWhisper(path, (_) {});
      final text = raw.trim();
      if (text.isEmpty || text.startsWith('(no speech')) return;
      _lines.add(TranscriptLine(
        isMe: isMe,
        text: text,
        timestamp: DateTime.now(),
      ));
      notifyListeners();
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// Saves the full call audio to Documents and runs post-call transcription
  /// to produce per-speaker timestamped text and a merged conversation file.
  Future<void> _persistAndPostTranscribe() async {
    final startedAt = _callStartedAt;
    if (startedAt == null) return;

    final myPcm = _myFullBuf.takeBytes();
    final otherPcm = _otherFullBuf.takeBytes();
    if (myPcm.isEmpty && otherPcm.isEmpty) return;

    final dir = await callsDir();
    final slug = _slugFor(startedAt);

    final myPath = '${dir.path}/${slug}_me.wav';
    final otherPath = '${dir.path}/${slug}_other.wav';

    _status = 'Saving recording…';
    notifyListeners();

    await File(myPath).writeAsBytes(
      CactusService.buildWav(myPcm, sampleRate, channels, bitsPerSample),
    );
    await File(otherPath).writeAsBytes(
      CactusService.buildWav(otherPcm, sampleRate, channels, bitsPerSample),
    );

    final myOffsetMs = _offsetMsFromCallStart(_myFirstFrameAt);
    final otherOffsetMs = _offsetMsFromCallStart(_otherFirstFrameAt);

    _status = 'Transcribing my audio…';
    notifyListeners();
    final mySegs = await _safeTranscribeSegments(myPath);
    await _writeSegmentsFile(
      '${dir.path}/${slug}_me.txt',
      mySegs,
      offsetMs: myOffsetMs,
    );

    _status = 'Transcribing other audio…';
    notifyListeners();
    final otherSegs = await _safeTranscribeSegments(otherPath);
    await _writeSegmentsFile(
      '${dir.path}/${slug}_other.txt',
      otherSegs,
      offsetMs: otherOffsetMs,
    );

    _status = 'Building conversation…';
    notifyListeners();
    final convPath = '${dir.path}/${slug}_conversation.txt';
    await _writeConversationFile(
      convPath,
      mySegs,
      otherSegs,
      myOffsetMs: myOffsetMs,
      otherOffsetMs: otherOffsetMs,
    );
  }

  int _offsetMsFromCallStart(DateTime? firstFrameAt) {
    final start = _callStartedAt;
    if (start == null || firstFrameAt == null) return 0;
    final diff = firstFrameAt.difference(start).inMilliseconds;
    return diff < 0 ? 0 : diff;
  }

  Future<List<WhisperSegment>> _safeTranscribeSegments(String path) async {
    try {
      return await CactusService.instance
          .transcribeWhisperSegments(path, (_) {});
    } catch (e) {
      _error = 'Transcription failed for $path: $e';
      notifyListeners();
      return const [];
    }
  }

  Future<void> _writeSegmentsFile(
    String path,
    List<WhisperSegment> segments, {
    int offsetMs = 0,
  }) async {
    final buf = StringBuffer();
    for (final s in segments) {
      buf.writeln('[${_formatStamp(s.startMs + offsetMs)}] ${s.text}');
    }
    await File(path).writeAsString(buf.toString());
  }

  Future<void> _writeConversationFile(
    String path,
    List<WhisperSegment> mine,
    List<WhisperSegment> other, {
    int myOffsetMs = 0,
    int otherOffsetMs = 0,
  }) async {
    final entries = <_LabeledSegment>[
      for (final s in mine) _LabeledSegment(true, s.startMs + myOffsetMs, s.text),
      for (final s in other)
        _LabeledSegment(false, s.startMs + otherOffsetMs, s.text),
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));

    final buf = StringBuffer();
    for (final e in entries) {
      buf.writeln('${e.isMe ? 'Me' : 'Other'}: ${e.text}');
    }
    await File(path).writeAsString(buf.toString());
  }

  /// Returns the directory where call recordings are stored, creating it if
  /// necessary.
  static Future<Directory> callsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$callsDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Lists saved calls (newest first), reading whatever files exist on disk.
  static Future<List<SavedCall>> listSavedCalls() async {
    final dir = await callsDir();
    final entries = await dir.list().toList();
    final bySlug = <String, _CallFiles>{};
    for (final entry in entries) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final match = _callFilePattern.firstMatch(name);
      if (match == null) continue;
      final slug = match.group(1)!;
      final kind = match.group(2)!;
      final files = bySlug.putIfAbsent(slug, () => _CallFiles());
      switch (kind) {
        case 'me.wav':
          files.myWav = entry;
        case 'other.wav':
          files.otherWav = entry;
        case 'me.txt':
          files.myTranscript = entry;
        case 'other.txt':
          files.otherTranscript = entry;
        case 'conversation.txt':
          files.conversation = entry;
        case 'story.txt':
          files.story = entry;
      }
    }

    final result = <SavedCall>[];
    bySlug.forEach((slug, f) {
      if (f.myWav == null || f.otherWav == null) return;
      final startedAt = _parseSlug(slug);
      if (startedAt == null) return;
      result.add(SavedCall(
        startedAt: startedAt,
        slug: slug,
        myWav: f.myWav!,
        otherWav: f.otherWav!,
        myTranscript: f.myTranscript,
        otherTranscript: f.otherTranscript,
        conversation: f.conversation,
        story: f.story,
      ));
    });
    result.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return result;
  }

  static String _slugFor(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)}T'
        '${two(l.hour)}-${two(l.minute)}-${two(l.second)}';
  }

  static DateTime? _parseSlug(String slug) {
    final m = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})$',
    ).firstMatch(slug);
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }

  static String _formatStamp(int ms) {
    final totalSeconds = ms ~/ 1000;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    final millis = ms % 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    final base =
        '${two(m)}:${two(s)}.${millis.toString().padLeft(3, '0')}';
    return h > 0 ? '${two(h)}:$base' : base;
  }
}

class _LabeledSegment {
  final bool isMe;
  final int startMs;
  final String text;
  _LabeledSegment(this.isMe, this.startMs, this.text);
}

class _CallFiles {
  File? myWav;
  File? otherWav;
  File? myTranscript;
  File? otherTranscript;
  File? conversation;
  File? story;
}

final RegExp _callFilePattern = RegExp(
  r'^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})_(me\.wav|other\.wav|me\.txt|other\.txt|conversation\.txt|story\.txt)$',
);
