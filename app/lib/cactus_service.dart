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

class TranscriptSegment {
  final int startMs;
  final int endMs;
  final String text;

  const TranscriptSegment({
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
  static const _vadDirName = 'silero-vad-int4';

  // Gemma can only process <10s of audio per call on device (OOM otherwise).
  static const double _vadMaxSpeechSec = 10.0;

  CactusModelT? _model;
  CactusModelT? _whisperModel;
  CactusModelT? _vadModel;

  Future<String> _modelsRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  Future<void> init(void Function(CactusProgress) onProgress) async {
    if (_model != null) return;
    _unloadWhisper();
    _unloadVad();
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

  Future<String> complete(String prompt, {String? optionsJson}) async {
    final model = _model;
    if (model == null) throw StateError('Model not initialized');
    final messages = jsonEncode([
      {'role': 'user', 'content': prompt},
    ]);
    final raw = cactusComplete(model, messages, optionsJson, null, null);
    if (kDebugMode) {
      // Full native result (JSON with response + metadata) streamed to the
      // flutter console on the dev machine. On device we return just the
      // response text below.
      debugPrint('[cactus.complete] raw: $raw');
    }
    return _extractCompletionText(raw);
  }

  static String _extractCompletionText(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final response = decoded['response'];
        if (response is String) return response;
      }
    } catch (_) {
      // Not JSON — fall through and return raw.
    }
    return raw;
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
    _unloadGemma();
    _unloadVad();
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
    return '(no speech — raw: $resultJson)';
  }

  Future<void> initVad(void Function(CactusProgress) onProgress) async {
    if (_vadModel != null) return;
    _unloadGemma();
    _unloadWhisper();
    final root = await _modelsRoot();
    final modelDir = Directory('$root/$_vadDirName');
    if (!await modelDir.exists()) {
      throw Exception(
        'VAD model not found at ${modelDir.path}\n'
        'Place the "$_vadDirName" folder in the app Documents directory.',
      );
    }
    onProgress(
      const CactusProgress(CactusStage.loading, message: 'Loading VAD…'),
    );
    _vadModel = cactusInit(modelDir.path, null, false);
  }

  /// Runs VAD over [audioPath] and transcribes each speech region with Gemma.
  /// VAD is configured to cap each region at [_vadMaxSpeechSec] so Gemma never
  /// sees more than ~9s of audio (OOM threshold on-device).
  Future<List<TranscriptSegment>> transcribeGemmaSegments(
    String audioPath,
    void Function(CactusProgress) onProgress,
  ) async {
    final vadRanges = await _runVad(audioPath, onProgress);
    if (vadRanges.isEmpty) return const [];

    await init(onProgress);

    final fileBytes = await File(audioPath).readAsBytes();
    final info = _parseWavHeader(fileBytes);
    final pcm = Uint8List.sublistView(fileBytes, info.dataOffset);
    final bytesPerSample = info.channels * (info.bitsPerSample ~/ 8);

    final tmpDir = await getTemporaryDirectory();
    final out = <TranscriptSegment>[];

    for (var i = 0; i < vadRanges.length; i++) {
      final range = vadRanges[i];
      onProgress(CactusProgress(
        CactusStage.generating,
        message: 'Transcribing ${i + 1}/${vadRanges.length}…',
      ));

      final startByte =
          (range.startMs * info.sampleRate ~/ 1000) * bytesPerSample;
      final endByte =
          (range.endMs * info.sampleRate ~/ 1000) * bytesPerSample;
      final sStart = startByte.clamp(0, pcm.length);
      final sEnd = endByte.clamp(sStart, pcm.length);
      if (sEnd - sStart < bytesPerSample * info.sampleRate ~/ 10) continue;

      final chunkWav = buildWav(
        Uint8List.sublistView(pcm, sStart, sEnd),
        info.sampleRate,
        info.channels,
        info.bitsPerSample,
      );
      final tmpPath =
          '${tmpDir.path}/cactus_vad_chunk_${DateTime.now().microsecondsSinceEpoch}_$i.wav';
      await File(tmpPath).writeAsBytes(chunkWav);

      try {
        final resultJson = await Future(
          () => cactusTranscribe(
            _model!,
            tmpPath,
            'You are transcribing a phone call spoken in English. '
                'Output only the literal English words spoken in the audio, '
                'verbatim, with no translation, no commentary, and no '
                'speaker labels. If the audio contains no clearly '
                'intelligible English speech (e.g. silence, background '
                'noise, music, coughs, breathing, keyboard clicks, or '
                'unintelligible sounds), output exactly: [NO_SPEECH]',
            '{"temperature":0.0}',
            null,
            null,
          ),
        );
        if (kDebugMode) {
          debugPrint('[cactus.transcribe] chunk $i raw: $resultJson');
        }
        final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
        final text = ((decoded['response'] as String?) ?? '').trim();
        if (_isNoiseTranscription(text)) continue;
        out.add(TranscriptSegment(
          startMs: range.startMs,
          endMs: range.endMs,
          text: text,
        ));
      } finally {
        await File(tmpPath).delete().catchError((Object _) => File(tmpPath));
      }
    }
    return out;
  }

  Future<List<_MsRange>> _runVad(
    String audioPath,
    void Function(CactusProgress) onProgress,
  ) async {
    await initVad(onProgress);
    onProgress(
      const CactusProgress(
        CactusStage.generating,
        message: 'Detecting speech…',
      ),
    );
    final options = jsonEncode({
      'threshold': 0.6,
      'max_speech_duration_s': _vadMaxSpeechSec,
      'min_silence_duration_ms': 400,
      'speech_pad_ms': 100,
    });
    final resultJson = await Future(
      () => cactusVad(_vadModel!, audioPath, options, null),
    );
    if (kDebugMode) {
      debugPrint('[cactus.vad] raw: $resultJson');
    }
    final decoded = jsonDecode(resultJson) as Map<String, dynamic>;
    final segments = (decoded['segments'] as List? ?? []);
    // VAD resamples to 16kHz internally and returns sample indices at that rate.
    const vadRate = 16000;
    return [
      for (final raw in segments)
        if (raw is Map<String, dynamic>)
          _MsRange(
            startMs: ((raw['start'] as num).toInt() * 1000 / vadRate).round(),
            endMs: ((raw['end'] as num).toInt() * 1000 / vadRate).round(),
          ),
    ];
  }

  static bool _isNoiseTranscription(String text) {
    if (text.isEmpty) return true;
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');
    if (normalized.isEmpty) return true;
    const noiseMarkers = {
      'nospeech',
      'noaudio',
      'silence',
      'inaudible',
      'unintelligible',
      'noise',
      'backgroundnoise',
      'music',
    };
    if (noiseMarkers.contains(normalized)) return true;
    // Gemma sometimes wraps the sentinel, e.g. "[NO_SPEECH]." or "(no speech)".
    if (normalized.contains('nospeech')) return true;
    return false;
  }

  static _WavInfo _parseWavHeader(Uint8List bytes) {
    int sampleRate = 16000, channels = 1, bitsPerSample = 16, dataOffset = 44;
    var pos = 12;
    while (pos + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
      final size = ByteData.sublistView(
        bytes,
        pos + 4,
        pos + 8,
      ).getUint32(0, Endian.little);
      if (id == 'fmt ') {
        final bd = ByteData.sublistView(bytes, pos + 8);
        channels = bd.getUint16(2, Endian.little);
        sampleRate = bd.getUint32(4, Endian.little);
        bitsPerSample = bd.getUint16(14, Endian.little);
      } else if (id == 'data') {
        dataOffset = pos + 8;
        break;
      }
      pos += 8 + size;
    }
    return _WavInfo(
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bitsPerSample,
      dataOffset: dataOffset,
    );
  }

  void _unloadGemma() {
    if (_model != null) {
      cactusDestroy(_model!);
      _model = null;
    }
  }

  void _unloadWhisper() {
    if (_whisperModel != null) {
      cactusDestroy(_whisperModel!);
      _whisperModel = null;
    }
  }

  void _unloadVad() {
    if (_vadModel != null) {
      cactusDestroy(_vadModel!);
      _vadModel = null;
    }
  }

  void dispose() {
    _unloadGemma();
    _unloadWhisper();
    _unloadVad();
  }
}

class _MsRange {
  final int startMs;
  final int endMs;
  const _MsRange({required this.startMs, required this.endMs});
}

class _WavInfo {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataOffset;
  const _WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
  });
}
