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

class CallTranscriber extends ChangeNotifier {
  CallTranscriber._();
  static final CallTranscriber instance = CallTranscriber._();

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bitsPerSample = 16;
  static const Duration flushInterval = Duration(seconds: 8);
  // Skip chunks with fewer samples than this (less than ~0.5s of audio).
  static const int minBytesToTranscribe = sampleRate * 2 ~/ 2;

  final List<TranscriptLine> _lines = [];
  List<TranscriptLine> get lines => List.unmodifiable(_lines);

  final BytesBuilder _myBuf = BytesBuilder(copy: true);
  final BytesBuilder _otherBuf = BytesBuilder(copy: true);

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
    _myBuf.clear();
    _otherBuf.clear();
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
    _status = null;
    notifyListeners();
  }

  void addMyFrame(Uint8List? bytes) {
    if (!_active || bytes == null || bytes.isEmpty) return;
    _myBuf.add(bytes);
  }

  void addOtherFrame(Uint8List? bytes) {
    if (!_active || bytes == null || bytes.isEmpty) return;
    _otherBuf.add(bytes);
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  Future<void> _flush() async {
    if (_busy) return;
    _busy = true;
    try {
      if (_myBuf.length >= minBytesToTranscribe) {
        final bytes = _myBuf.takeBytes();
        await _transcribeAndAppend(bytes, isMe: true);
      }
      if (_otherBuf.length >= minBytesToTranscribe) {
        final bytes = _otherBuf.takeBytes();
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
}
