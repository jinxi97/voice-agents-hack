import 'dart:io';

import 'cactus_service.dart';
import 'call_transcriber.dart';

class StoryGenerator {
  StoryGenerator._();
  static final instance = StoryGenerator._();

  Future<File> generate(
    SavedCall call, {
    void Function(String status)? onStatus,
  }) async {
    final me = await _readOrEmpty(call.myTranscript);
    final other = await _readOrEmpty(call.otherTranscript);
    if (me.trim().isEmpty && other.trim().isEmpty) {
      throw Exception('Both transcripts are empty — nothing to write about.');
    }

    onStatus?.call('Loading Gemma…');
    await CactusService.instance.init((p) {
      if (p.message != null) onStatus?.call(p.message!);
    });

    onStatus?.call('Generating story…');
    final prompt = _buildPrompt(me: me, other: other);
    final raw = await CactusService.instance.complete(prompt);
    final story = raw.trim();

    final dir = await CallTranscriber.callsDir();
    final path = '${dir.path}/${call.slug}_story.txt';
    final file = File(path);
    await file.writeAsString(story);
    return file;
  }

  static Future<String> _readOrEmpty(File? f) async {
    if (f == null) return '';
    try {
      return await f.readAsString();
    } catch (_) {
      return '';
    }
  }

  static String _buildPrompt({required String me, required String other}) {
    return '''You are a thoughtful narrator. Below are two timestamped transcripts from a single phone call — one captured from "Me" (a kid) and one from the "Other" (the grandpa) speaker. Lines are formatted as "[mm:ss.mmm] text".

Using both transcripts together, write a narrative story that captures what was discussed, especailly what is the story that grandpa or kid told. Capture the full story (time, location, people) and memorable parts. Write in the grandpa's first person. Do not include timestamps, speaker labels, bullet points, or headings — just the story.

Here is an example story:
'When I was a little girl, we had a cherry tree in the backyard that your great-grandfather planted the year I was born.
Every July it would bloom with so many cherries that my mother would bake pies for the whole street.
I remember climbing up with my cousin Lila and eating until our lips were stained purple.
That tree outlived three dogs and two moves — and every spring I still think of the smell of those blossoms.'

Now please write the story based on the transcript below:

--- Me (kid) transcript ---
$me

--- Other (grandpa) transcript ---
$other

Story:''';
  }
}
