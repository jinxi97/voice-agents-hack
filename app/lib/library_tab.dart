import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'artifact.dart';
import 'artifact_progress_page.dart';
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

class StoryStore extends ChangeNotifier {
  StoryStore._();
  static final StoryStore instance = StoryStore._();

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

  List<Story> get stories => List.unmodifiable(_stories);

  Story add({required String title, required String subtitle, required String text}) {
    final story = Story(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      subtitle: subtitle,
      text: text,
    );
    _stories.add(story);
    notifyListeners();
    return story;
  }

  void remove(String id) {
    _stories.removeWhere((s) => s.id == id);
    notifyListeners();
  }

  void touch() => notifyListeners();
}

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {

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

    final stories = StoryStore.instance.stories;
    for (var i = 0; i < stories.length; i++) {
      final s = stories[i];
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

  void _startInteractiveBook() {
    final artifact = ArtifactStore.instance.create(ArtifactKind.interactiveBook);
    unawaited(_runInteractiveBook(artifact));
  }

  Future<void> _runInteractiveBook(Artifact artifact) async {
    try {
      final request = await _buildBookRequest();
      final sink = StringBuffer();
      await for (final chunk in GeminiService.instance.generateTextStream(
        request.prompt,
        images: request.images,
      )) {
        sink.write(chunk);
        artifact.chunksReceived += 1;
        artifact.partialText = sink.toString();
        ArtifactStore.instance.touch();
      }
      var html = stripCodeFence(sink.toString());
      request.replacements.forEach((placeholder, dataUrl) {
        html = html.replaceAll(placeholder, dataUrl);
      });
      artifact.htmlContent = html;
      artifact.status = ArtifactStatus.ready;
      ArtifactStore.instance.touch();
    } catch (e) {
      artifact.status = ArtifactStatus.failed;
      artifact.error = e.toString();
      ArtifactStore.instance.touch();
    }
  }

  Future<bool?> _confirmDelete(BuildContext context, Story story) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete story?'),
        content: Text('"${story.title}" will be removed from your Library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _openArtifact(Artifact a) {
    switch (a.status) {
      case ArtifactStatus.ready:
        if (a.htmlContent != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => InteractiveBookPage(html: a.htmlContent!),
            ),
          );
        }
        break;
      case ArtifactStatus.failed:
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Generation failed'),
            content: SingleChildScrollView(
              child: Text(a.error ?? 'Unknown error'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        break;
      case ArtifactStatus.generating:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArtifactProgressPage(artifact: a),
          ),
        );
        break;
    }
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
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _startInteractiveBook,
                icon: const Icon(Icons.menu_book),
                label: const Text('Generate interactive book'),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: ArtifactStore.instance,
            builder: (context, _) {
              final artifacts = ArtifactStore.instance.artifacts;
              if (artifacts.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Artifacts',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 110,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: artifacts.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (_, i) => _ArtifactCard(
                          artifact: artifacts[i],
                          onTap: () => _openArtifact(artifacts[i]),
                          onDismiss: () =>
                              ArtifactStore.instance.remove(artifacts[i].id),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: StoryStore.instance,
              builder: (context, _) {
                final stories = StoryStore.instance.stories;
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: stories.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, i) {
                    final story = stories[i];
                    return Dismissible(
                      key: ValueKey(story.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        color: Colors.red,
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      confirmDismiss: (_) => _confirmDelete(context, story),
                      onDismissed: (_) => StoryStore.instance.remove(story.id),
                      child: Card(
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
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'delete') {
                                final ok = await _confirmDelete(context, story);
                                if (ok == true) {
                                  StoryStore.instance.remove(story.id);
                                }
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(Icons.delete_outline),
                                  title: Text('Delete'),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ],
                          ),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => StoryPage(story: story),
                              ),
                            );
                            if (mounted) setState(() {});
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  final Artifact artifact;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  const _ArtifactCard({
    required this.artifact,
    required this.onTap,
    required this.onDismiss,
  });

  IconData get _icon => Icons.menu_book;

  String _formatTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 5) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_icon, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        artifact.displayTitle,
                        style: Theme.of(context).textTheme.labelLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (artifact.status != ArtifactStatus.generating)
                      InkWell(
                        onTap: onDismiss,
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(Icons.close, size: 16),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(child: _statusBody(context)),
                Text(
                  _formatTime(artifact.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusBody(BuildContext context) {
    switch (artifact.status) {
      case ArtifactStatus.generating:
        return Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Generating… ${artifact.chunksReceived} chunks',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
      case ArtifactStatus.ready:
        return Row(
          children: [
            Icon(Icons.check_circle, size: 16, color: Colors.green[400]),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Ready — tap to open',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
      case ArtifactStatus.failed:
        return Row(
          children: [
            const Icon(Icons.error, size: 16, color: Colors.redAccent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Failed — tap for details',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
    }
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
