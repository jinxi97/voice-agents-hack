import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'gemini_service.dart';
import 'interactive_book_page.dart';

class Story {
  final String id;
  final String title;
  final String subtitle;
  final String text;
  File? photo;

  Story({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.text,
    this.photo,
  });
}

final List<Story> _stories = [
  Story(
    id: '1',
    title: 'The Cherry Tree in the Backyard',
    subtitle: 'Grandma, summer 1962',
    text:
        'When I was a little girl, we had a cherry tree in the backyard that your '
        'great-grandfather planted the year I was born. Every July it would bloom '
        'with so many cherries that my mother would bake pies for the whole street. '
        'I remember climbing up with my cousin Lila and eating until our lips were '
        'stained purple. That tree outlived three dogs and two moves — and every '
        'spring I still think of the smell of those blossoms.',
  ),
  Story(
    id: '2',
    title: 'How I Met Your Grandfather',
    subtitle: 'Grandma, autumn 1968',
    text:
        'It was at a dance hall on the corner of 4th and Main. I was wearing a '
        'yellow dress that my sister had sewn for me, and I was certain I was the '
        'tallest girl in the room. Your grandfather came over — he was terrible at '
        'dancing, truly awful — but he made me laugh so hard I forgot to be '
        'embarrassed. He walked me home afterward in the rain and I remember '
        'thinking, this is the one I\'m going to marry. And three years later, I did.',
  ),
  Story(
    id: '3',
    title: 'The Long Winter of \'78',
    subtitle: 'Grandma, winter 1978',
    text:
        'The snow came down for four days straight. Your mother was only six and '
        'she thought it was the most magical thing in the world. We ran out of milk '
        'and bread by the second day, and the roads were completely impassable. Mr. '
        'Henderson from down the road came by on his tractor with a crate of '
        'supplies for every family on the block. I never forgot that kindness. That '
        'was the kind of neighborhood we had then.',
  ),
];

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  bool _generating = false;
  final ValueNotifier<String> _streamText = ValueNotifier('');

  @override
  void dispose() {
    _streamText.dispose();
    super.dispose();
  }

  String _photoPlaceholder(int i) => '__PHOTO_${i + 1}__';

  String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }

  Future<({String prompt, List<GeminiImage> images, Map<String, String> replacements})>
      _buildBookRequest() async {
    final buf = StringBuffer();
    final images = <GeminiImage>[];
    final replacements = <String, String>{};

    buf.writeln(
      'Create a complete, standalone, mobile-friendly interactive HTML webpage '
      'that presents the following family stories as a beautiful digital keepsake book. '
      'Include all CSS in a <style> tag and all JS in <script> tags — no external '
      'resources, no CDN links. Use warm, elegant typography (system fonts). '
      'Add interactivity: a cover page, tap/swipe to turn pages, a table of contents, '
      'and smooth transitions.\n\n'
      'Some stories have a photo attached (provided as inline images below, in the same '
      'order as the stories that reference them). For each story that has a photo, embed '
      'it in the layout using an <img> tag whose src attribute is the exact placeholder '
      'token shown under "Photo placeholder" for that story. Use the placeholder VERBATIM '
      '(including the underscores). Do not rename, decode, inline, or alter it — we will '
      'substitute it after generation. You may still use the photo content to inform '
      'captions and layout choices.\n\n'
      'Respond with ONLY the raw HTML document, starting with <!DOCTYPE html>. '
      'No markdown, no code fences, no commentary.\n\n'
      'Stories:\n',
    );

    for (var i = 0; i < _stories.length; i++) {
      final s = _stories[i];
      buf.writeln('--- Story ${i + 1} ---');
      buf.writeln('Title: ${s.title}');
      buf.writeln('Byline: ${s.subtitle}');
      if (s.photo != null) {
        final placeholder = _photoPlaceholder(i);
        final bytes = await s.photo!.readAsBytes();
        final mime = _mimeFromPath(s.photo!.path);
        images.add((mimeType: mime, bytes: bytes));
        replacements[placeholder] = 'data:$mime;base64,${base64Encode(bytes)}';
        buf.writeln('Photo placeholder: $placeholder');
      } else {
        buf.writeln('Photo placeholder: (none — do not include an img tag)');
      }
      buf.writeln('Body:');
      buf.writeln(s.text);
      buf.writeln();
    }

    return (prompt: buf.toString(), images: images, replacements: replacements);
  }

  Future<void> _generateInteractiveBook() async {
    if (_generating) return;
    setState(() => _generating = true);
    _streamText.value = '';

    final scrollController = ScrollController();
    var dialogOpen = true;
    void closeDialog() {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
      }
    }

    // Fire-and-forget: the dialog future resolves when we pop it.
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _StreamingDialog(
          textNotifier: _streamText,
          scrollController: scrollController,
        ),
      ).then((_) => dialogOpen = false),
    );

    try {
      final request = await _buildBookRequest();
      final sink = StringBuffer();
      await for (final chunk in GeminiService.instance.generateTextStream(
        request.prompt,
        images: request.images,
      )) {
        sink.write(chunk);
        _streamText.value = sink.toString();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scrollController.hasClients) {
            scrollController.jumpTo(scrollController.position.maxScrollExtent);
          }
        });
      }
      if (!mounted) return;
      closeDialog();
      var html = stripCodeFence(sink.toString());
      request.replacements.forEach((placeholder, dataUrl) {
        html = html.replaceAll(placeholder, dataUrl);
      });
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => InteractiveBookPage(html: html)),
      );
    } catch (e) {
      closeDialog();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Generation failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _generatePdf() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Generate printable PDF — not wired up yet')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              'Stories',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Tap a story to read it or hear it in grandma\'s voice.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _generating ? null : _generateInteractiveBook,
                    icon: _generating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.menu_book),
                    label: Text(_generating ? 'Generating…' : 'Interactive book'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _generatePdf,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Printable PDF'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _stories.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final story = _stories[i];
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundImage:
                          story.photo != null ? FileImage(story.photo!) : null,
                      child: story.photo == null
                          ? const Icon(Icons.auto_stories)
                          : null,
                    ),
                    title: Text(story.title),
                    subtitle: Text(story.subtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => StoryPage(story: story),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamingDialog extends StatelessWidget {
  final ValueNotifier<String> textNotifier;
  final ScrollController scrollController;
  const _StreamingDialog({
    required this.textNotifier,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text('Writing your book…'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 280,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ValueListenableBuilder<String>(
            valueListenable: textNotifier,
            builder: (_, text, __) => SingleChildScrollView(
              controller: scrollController,
              child: Text(
                text.isEmpty ? 'Waiting for first token…' : text,
                style: const TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StoryPage extends StatefulWidget {
  final Story story;
  const StoryPage({super.key, required this.story});

  @override
  State<StoryPage> createState() => _StoryPageState();
}

class _StoryPageState extends State<StoryPage> {
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickPhoto() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2000,
      );
      if (picked == null) return;
      setState(() => widget.story.photo = File(picked.path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not pick photo: $e')),
      );
    }
  }

  void _playVoice() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Playing grandma\'s voice… (not wired up yet)')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.story;
    return Scaffold(
      appBar: AppBar(
        title: Text(story.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Play grandma\'s voice',
            onPressed: _playVoice,
            icon: const Icon(Icons.play_circle_fill),
            iconSize: 32,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(
            story.subtitle,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 20),
          _PhotoSlot(photo: story.photo, onTap: _pickPhoto),
          const SizedBox(height: 24),
          SelectableText(
            story.text,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(height: 1.6, fontSize: 17),
          ),
        ],
      ),
    );
  }
}

class _PhotoSlot extends StatelessWidget {
  final File? photo;
  final VoidCallback onTap;
  const _PhotoSlot({required this.photo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: photo != null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(photo!, fit: BoxFit.cover),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.edit, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text(
                              'Change photo',
                              style: TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 48,
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add a photo for this story',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
