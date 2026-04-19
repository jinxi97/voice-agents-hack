import 'package:flutter/material.dart';

import 'artifact.dart';
import 'interactive_book_page.dart';

class ArtifactProgressPage extends StatefulWidget {
  final Artifact artifact;
  const ArtifactProgressPage({super.key, required this.artifact});

  @override
  State<ArtifactProgressPage> createState() => _ArtifactProgressPageState();
}

class _ArtifactProgressPageState extends State<ArtifactProgressPage> {
  final ScrollController _scroll = ScrollController();
  bool _didNavigate = false;

  @override
  void initState() {
    super.initState();
    ArtifactStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    ArtifactStore.instance.removeListener(_onChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });

    if (_didNavigate) return;
    final a = widget.artifact;
    if (a.status == ArtifactStatus.ready) {
      _didNavigate = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => InteractiveBookPage(html: a.htmlContent!),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.artifact;
    const title = 'Writing your book…';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (a.status == ArtifactStatus.generating) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ],
                Text(
                  '${a.chunksReceived} chunks received',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            if (a.status == ArtifactStatus.failed) ...[
              const SizedBox(height: 8),
              Text(
                a.error ?? 'Generation failed',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: Text(
                    a.partialText.isEmpty
                        ? 'Waiting for first token…'
                        : a.partialText,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
