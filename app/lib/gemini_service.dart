import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

typedef GeminiImage = ({String mimeType, Uint8List bytes});

const String _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
const String _model = 'gemini-3.1-pro-preview';

class GeminiService {
  GeminiService._();
  static final GeminiService instance = GeminiService._();

  Future<String> generateText(String prompt) async {
    if (_geminiApiKey.isEmpty) {
      throw Exception('GEMINI_API_KEY not set. Use --dart-define-from-file=.env.json');
    }
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$_geminiApiKey',
    );
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Gemini error ${res.statusCode}: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final candidates = body['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('Gemini returned no candidates: ${res.body}');
    }
    final parts = (candidates.first['content']?['parts'] as List?) ?? [];
    final text = parts.map((p) => p['text'] ?? '').join();
    if (text.isEmpty) {
      throw Exception('Gemini returned empty text: ${res.body}');
    }
    return text.toString();
  }

  Stream<String> generateTextStream(
    String prompt, {
    List<GeminiImage> images = const [],
    Map<String, dynamic>? generationConfig,
  }) async* {
    if (_geminiApiKey.isEmpty) {
      throw Exception('GEMINI_API_KEY not set. Use --dart-define-from-file=.env.json');
    }
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:streamGenerateContent?alt=sse&key=$_geminiApiKey',
    );
    final parts = <Map<String, dynamic>>[
      {'text': prompt},
      for (final img in images)
        {
          'inlineData': {
            'mimeType': img.mimeType,
            'data': base64Encode(img.bytes),
          },
        },
    ];
    final req = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'contents': [
          {'parts': parts},
        ],
        if (generationConfig != null) 'generationConfig': generationConfig,
      });
    final res = await http.Client().send(req);
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw Exception('Gemini error ${res.statusCode}: $body');
    }
    await for (final line in res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final payload = line.substring(6).trim();
      if (payload.isEmpty) continue;
      try {
        final body = jsonDecode(payload) as Map<String, dynamic>;
        final candidates = body['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) continue;
        final parts = (candidates.first['content']?['parts'] as List?) ?? [];
        for (final p in parts) {
          final t = p['text'];
          if (t is String && t.isNotEmpty) yield t;
        }
      } catch (_) {
        // ignore malformed chunk
      }
    }
  }
}

String stripCodeFence(String s) {
  var t = s.trim();
  final fence = RegExp(r'^```(?:html|HTML)?\s*\n([\s\S]*?)\n```\s*$');
  final m = fence.firstMatch(t);
  if (m != null) return m.group(1)!.trim();
  return t;
}
