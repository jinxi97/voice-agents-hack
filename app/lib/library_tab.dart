import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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
