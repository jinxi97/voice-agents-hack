import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'cactus.dart';

enum CactusStage { idle, loading, ready, generating, error }

class CactusProgress {
  final CactusStage stage;
  final double progress;
  final String? message;

  const CactusProgress(this.stage, {this.progress = 0, this.message});
}

class WhisperSegment {
  final int startMs;
  final int endMs;
  final String text;

  const WhisperSegment({
    required this.startMs,
    required this.endMs,
    required this.text,
  });
}

class CactusService {
  CactusService._();
  static final instance = CactusService._();

  static const _modelDirName = 'gemma-4-e4b-it-int4-apple';

  static const _whisperDirName = 'whisper-medium-int4-apple';

  CactusModelT? _model;

  CactusModelT? _whisperModel;

  Future<String> _modelsRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  Future<void> init(void Function(CactusProgress) onProgress) async {
    if (_model != null) return;
    if (_whisperModel != null) {
      cactusDestroy(_whisperModel!);
      _whisperModel = null;
    }
    final root = await _modelsRoot();
    final modelDir = Directory('$root/$_modelDirName');
    if (!await modelDir.exists()) {
      throw Exception(
        'Gemma model not found at ${modelDir.path}\n'
        'Place the "$_modelDirName" folder in the app Documents directory.',
      );
    }
    onProgress(
      const CactusProgress(CactusStage.loading, message: 'Loading Gemma…'),
    );
    _model = cactusInit(modelDir.path, null, false);
  }

  Future<String> complete(String prompt) async {
    final model = _model;
    if (model == null) throw StateError('Model not initialized');
    final messages = jsonEncode([
      {'role': 'user', 'content': prompt},
    ]);
    return cactusComplete(model, messages, null, null, null);
  }

  Future<void> transcribeAudioChunked(
    String audioPath,
    void Function(CactusProgress) onProgress,
    void Function(int chunk, int total, String text) onChunk, {
    int secondsPerChunk = 10,
  }) async {
    await init(onProgress);

    final fileBytes = await File(audioPath).readAsBytes();

    // Parse WAV chunks to find fmt and data
    int sampleRate = 16000, channels = 1, bitsPerSample = 16, dataOffset = 44;
    var pos = 12;
    while (pos + 8 <= fileBytes.length) {
      final id = String.fromCharCodes(fileBytes.sublist(pos, pos + 4));
      final size = ByteData.sublistView(
        fileBytes,
        pos + 4,
        pos + 8,
      ).getUint32(0, Endian.little);
      if (id == 'fmt ') {
        final bd = ByteData.sublistView(fileBytes, pos + 8);
        channels = bd.getUint16(2, Endian.little);
        sampleRate = bd.getUint32(4, Endian.little);
        bitsPerSample = bd.getUint16(14, Endian.little);
      } else if (id == 'data') {
        dataOffset = pos + 8;
        break;
      }
      pos += 8 + size;
    }

    final bytesPerChunk =
        secondsPerChunk * sampleRate * channels * (bitsPerSample ~/ 8);
    final pcm = Uint8List.sublistView(fileBytes, dataOffset);
    final total = (pcm.length / bytesPerChunk).ceil().clamp(1, 9999);

    final tmpDir = await getTemporaryDirectory();

    for (var i = 0; i < total; i++) {
      onProgress(CactusProgress(
          CactusStage.generating,
          message: 'Transcribing chunk ${i + 1}/$total…',
        ),
      );

      final start = i * bytesPerChunk;
      final end = (start + bytesPerChunk).clamp(0, pcm.length);
      final chunkWav = buildWav(
        Uint8List.sublistView(pcm, start, end),
        sampleRate,
        channels,
        bitsPerSample,
      );

      final tmpPath = '${tmpDir.path}/cactus_chunk_$i.wav';
      await File(tmpPath).writeAsBytes(chunkWav);

      try {
        final model = _model!;
        final messages = jsonEncode([
          {
            'role': 'user',
            'content': 'Please transcribe this audio accurately.',
            'audio': [tmpPath],
          }
        ]);
        final result = await Future(
          () => cactusComplete(model, messages, null, null, null),
        );
        onChunk(i + 1, total, result.trim());
      } finally {
        await File(tmpPath).delete().catchError((Object _) => File(tmpPath));
      }
    }
  }

  static Uint8List buildWav(
    Uint8List pcm,
    int sampleRate,
    int channels,
    int bitsPerSample,
  ) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final out = ByteData(44 + pcm.length);
    void cc(int off, String s) {
      for (var i = 0; i < 4; i++) {
        out.setUint8(off + i, s.codeUnitAt(i));
      }
    }
    cc(0, 'RIFF');
    out.setUint32(4, 36 + pcm.length, Endian.little);
    cc(8, 'WAVE');
    cc(12, 'fmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little);
    out.setUint16(22, channels, Endian.little);
    out.setUint32(24, sampleRate, Endian.little);
    out.setUint32(28, byteRate, Endian.little);
    out.setUint16(32, blockAlign, Endian.little);
    out.setUint16(34, bitsPerSample, Endian.little);
    cc(36, 'data');
    out.setUint32(40, pcm.length, Endian.little);
    final buf = out.buffer.asUint8List();
    buf.setRange(44, 44 + pcm.length, pcm);
    return buf;
  }

  Future<void> initWhisper(void Function(CactusProgress) onProgress) async {
    if (_whisperModel != null) return;
    if (_model != null) {
      cactusDestroy(_model!);
      _model = null;
    }
    final root = await _modelsRoot();
    final modelDir = Directory('$root/$_whisperDirName');
    if (!await modelDir.exists()) {
      throw Exception(
        'Whisper model not found at ${modelDir.path}\n'
        'Place the "$_whisperDirName" folder in the app Documents directory.',
      );
    }
    onProgress(
      const CactusProgress(CactusStage.loading, message: 'Loading Whisper…'),
    );
    _whisperModel = cactusInit(modelDir.path, null, false);
  }

  Future<String> transcribeWhisper(
    String audioPath,
    void Function(CactusProgress) onProgress,
  ) async {
    await initWhisper(onProgress);
    onProgress(
      const CactusProgress(
        CactusStage.generating,
        message: 'Whisper transcribing…',
      ),
    );
    final resultJson = await Future(
      () => cactusTranscribe(
        _whisperModel!,
        audioPath,
        '<|startoftranscript|><|en|><|transcribe|><|notimestamps|>',
        '{"use_vad":true,"temperature":0.0}',
        null,
        null,
      ),
    );
    final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
    final segments = decoded['segments'] as List? ?? [];
    final response = (decoded['response'] as String? ?? '').trim();
    if (segments.isNotEmpty) {
      return segments.map((s) => (s['text'] as String).trim()).join(' ');
    }
    if (response.isNotEmpty) return response;
    // Surface raw JSON so the caller can see what Whisper actually returned
    return '(no speech — raw: $resultJson)';
  }

  /// Transcribes [audioPath] with Whisper and returns timestamped segments.
  /// Timestamps are converted to milliseconds (whisper.cpp emits centiseconds
  /// in `t0`/`t1`).
  Future<List<WhisperSegment>> transcribeWhisperSegments(
    String audioPath,
    void Function(CactusProgress) onProgress,
  ) async {
    await initWhisper(onProgress);
    onProgress(
      const CactusProgress(
        CactusStage.generating,
        message: 'Whisper transcribing…',
      ),
    );
    final resultJson = await Future(
      () => cactusTranscribe(
        _whisperModel!,
        audioPath,
        '<|startoftranscript|><|en|><|transcribe|>',
        '{"temperature":0.0,"no_timestamps":false,'
            '"token_timestamps":true,"max_len":60,"split_on_word":true,'
            '"cloud_handoff":false}',
        null,
        null,
      ),
    );
    if (kDebugMode) {
      // Useful when timestamps look wrong — confirm what cactus actually sent.
      // ignore: avoid_print
      print('whisper segments raw: $resultJson');
    }
    final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
    final segments = decoded['segments'] as List? ?? [];
    final out = <WhisperSegment>[];
    for (final raw in segments) {
      final s = raw as Map<String, dynamic>;
      final text = ((s['text'] as String?) ?? '').trim();
      if (text.isEmpty) continue;
      final t0 = _readSegmentMs(s, const ['t0', 'start_ms', 'startMs', 'start']);
      final t1 = _readSegmentMs(s, const ['t1', 'end_ms', 'endMs', 'end']) ?? t0;
      out.addAll(_splitSegmentOnSentences(WhisperSegment(
        startMs: t0 ?? 0,
        endMs: t1 ?? (t0 ?? 0),
        text: text,
      )));
    }
    return out;
  }

  /// Splits a single Whisper segment on sentence-ending punctuation, dividing
  /// the segment's time window proportionally by character count.
  ///
  /// Whisper's cloud path tends to return one big segment per utterance even
  /// when there are clear sentence boundaries / pauses, so we split here to
  /// get usable per-sentence timestamps.
  static List<WhisperSegment> _splitSegmentOnSentences(WhisperSegment seg) {
    final pieces = <String>[];
    final matches = RegExp(r'[^.!?]+[.!?]+|\S[^.!?]*$').allMatches(seg.text);
    for (final m in matches) {
      final p = m.group(0)!.trim();
      if (p.isNotEmpty) pieces.add(p);
    }
    if (pieces.length <= 1) return [seg];
    final totalChars = pieces.fold<int>(0, (a, b) => a + b.length);
    final duration = seg.endMs - seg.startMs;
    final out = <WhisperSegment>[];
    var charsSoFar = 0;
    for (final p in pieces) {
      final startMs = totalChars == 0
          ? seg.startMs
          : seg.startMs + (charsSoFar * duration / totalChars).round();
      charsSoFar += p.length;
      final endMs = totalChars == 0
          ? seg.endMs
          : seg.startMs + (charsSoFar * duration / totalChars).round();
      out.add(WhisperSegment(startMs: startMs, endMs: endMs, text: p));
    }
    return out;
  }

  /// Reads the first present timestamp field and returns it in milliseconds.
  /// Treats values < 1000 as seconds (whisper "start"/"end" floats), values
  /// in [1000, 100000) as centiseconds (whisper.cpp `t0`/`t1`), and larger
  /// values as already-in-ms.
  static int? _readSegmentMs(Map<String, dynamic> seg, List<String> keys) {
    for (final k in keys) {
      final v = seg[k];
      if (v is num) {
        final d = v.toDouble();
        if (k == 'start' || k == 'end') return (d * 1000).round();
        if (d < 100000) return (d * 10).round(); // centiseconds → ms
        return d.round();
      }
    }
    return null;
  }

  void dispose() {
    if (_model != null) {
      cactusDestroy(_model!);
      _model = null;
    }
    if (_whisperModel != null) {
      cactusDestroy(_whisperModel!);
      _whisperModel = null;
    }
  }

}
