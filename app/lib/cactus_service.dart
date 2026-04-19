import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'cactus.dart';

enum CactusStage { idle, downloading, extracting, loading, ready, generating, error }

class ModelAudit {
  final int fileCount;
  final List<String> zeroByteFiles;
  final int totalBytes;

  const ModelAudit({
    required this.fileCount,
    required this.zeroByteFiles,
    required this.totalBytes,
  });

  String get totalMb => (totalBytes / 1024 / 1024).toStringAsFixed(1);
}

class CactusProgress {
  final CactusStage stage;
  final double progress;
  final String? message;

  const CactusProgress(this.stage, {this.progress = 0, this.message});
}

class CactusService {
  CactusService._();
  static final instance = CactusService._();

  static const _modelUrl =
      'https://huggingface.co/Cactus-Compute/gemma-4-E4B-it/resolve/main/weights/gemma-4-e4b-it-int4-apple.zip';
  static const _modelDirName = 'gemma-4-e4b-it-int4-apple';

  CactusModelT? _model;
  String? _modelPath;

  Future<String> _modelsRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  Future<String> ensureModel(void Function(CactusProgress) onProgress) async {
    if (_modelPath != null) return _modelPath!;

    final root = await _modelsRoot();
    final modelDir = Directory('$root/$_modelDirName');
    final markerFile = File('${modelDir.path}/.ready');

    if (await markerFile.exists()) {
      _modelPath = modelDir.path;
      return modelDir.path;
    }

    final zipFile = File('$root/$_modelDirName.zip');
    if (!await zipFile.exists() || await zipFile.length() == 0) {
      await _download(zipFile, onProgress);
    }

    await modelDir.create(recursive: true);
    onProgress(const CactusProgress(CactusStage.extracting, message: 'Extracting…'));
    await _extract(zipFile, modelDir.path, onProgress);
    await markerFile.writeAsString('ok');
    await zipFile.delete();

    _modelPath = modelDir.path;
    return modelDir.path;
  }

  Future<void> _download(File dest, void Function(CactusProgress) onProgress) async {
    if (await dest.exists()) await dest.delete();
    final req = http.Request('GET', Uri.parse(_modelUrl));
    final resp = await http.Client().send(req);
    if (resp.statusCode != 200) {
      throw Exception('Download failed: HTTP ${resp.statusCode}');
    }
    final total = resp.contentLength ?? 0;
    var received = 0;
    final sink = dest.openWrite();
    await resp.stream.listen((chunk) {
      sink.add(chunk);
      received += chunk.length;
      onProgress(CactusProgress(
        CactusStage.downloading,
        progress: total > 0 ? received / total : 0,
        message: '${_mb(received)} / ${_mb(total)} MB',
      ));
    }).asFuture<void>();
    await sink.close();
    final actual = await dest.length();
    if (total > 0 && actual != total) {
      throw Exception('Download incomplete: $actual / $total bytes');
    }
  }

  Future<void> _extract(
    File zipFile,
    String outRoot,
    void Function(CactusProgress) onProgress,
  ) async {
    final input = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      final total = archive.files.length;
      if (total == 0) {
        throw Exception(
            'Zip decoder returned 0 entries (zip size: ${await zipFile.length()} bytes)');
      }
      onProgress(CactusProgress(
        CactusStage.extracting,
        progress: 0,
        message: '0 / $total files',
      ));
      var done = 0;
      for (final entry in archive.files) {
        final outPath = '$outRoot/${entry.name}';
        if (!entry.isFile) {
          await Directory(outPath).create(recursive: true);
        } else {
          await File(outPath).parent.create(recursive: true);
          final sink = OutputFileStream(outPath, bufferSize: 65536);
          try {
            entry.decompress(sink);
          } finally {
            await sink.close();
          }
          entry.clear();
        }
        done++;
        if (done % 50 == 0 || done == total) {
          onProgress(CactusProgress(
            CactusStage.extracting,
            progress: done / total,
            message: '$done / $total files',
          ));
        }
      }
    } finally {
      await input.close();
    }
  }

  Future<void> init(void Function(CactusProgress) onProgress) async {
    if (_model != null) return;
    final path = await ensureModel(onProgress);
    final audit = await auditModelDir(path);
    if (audit.zeroByteFiles.isNotEmpty || audit.fileCount < 2000) {
      throw Exception(
          'Model dir looks wrong — ${audit.fileCount} files, ${audit.zeroByteFiles.length} zero-byte. '
          'Total: ${audit.totalMb} MB. '
          'First 5 zero-byte: ${audit.zeroByteFiles.take(5).join(", ")}');
    }
    onProgress(CactusProgress(
      CactusStage.loading,
      message: 'Loading model… (${audit.fileCount} files, ${audit.totalMb} MB)',
    ));
    _model = cactusInit(path, null, false);
  }

  Future<ModelAudit> auditModelDir(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      return ModelAudit(fileCount: 0, zeroByteFiles: const [], totalBytes: 0);
    }
    final zero = <String>[];
    var count = 0;
    var bytes = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        count++;
        final len = await entity.length();
        bytes += len;
        if (len == 0) zero.add(entity.path.split('/').last);
      }
    }
    return ModelAudit(fileCount: count, zeroByteFiles: zero, totalBytes: bytes);
  }

  Future<String> complete(String prompt) async {
    final model = _model;
    if (model == null) throw StateError('Model not initialized');
    final messages = jsonEncode([
      {'role': 'user', 'content': prompt}
    ]);
    return cactusComplete(model, messages, null, null, null);
  }

  void dispose() {
    if (_model != null) {
      cactusDestroy(_model!);
      _model = null;
    }
  }

  static String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
}
