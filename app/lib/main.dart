import 'dart:io';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'cactus_service.dart';

const String appId = String.fromEnvironment('AGORA_APP_ID');
const String token = String.fromEnvironment('AGORA_TOKEN');
const String channelName = String.fromEnvironment('AGORA_CHANNEL');

void main() {
  runApp(const VideoCallApp());
}

class VideoCallApp extends StatelessWidget {
  const VideoCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agora Video Call',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _tabs = [
    _VideoCallTab(),
    _LibraryTab(),
    _SettingsTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabs[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.videocam), label: 'Video Call'),
          NavigationDestination(icon: Icon(Icons.bug_report), label: 'Debug'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class _VideoCallTab extends StatelessWidget {
  const _VideoCallTab();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CallPage()),
        ),
        child: Container(
          width: 96,
          height: 96,
          decoration: const BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.call, size: 40, color: Colors.white),
        ),
      ),
    );
  }
}

class _ChatMessage {
  final String text;
  final bool isUser;
  _ChatMessage({required this.text, required this.isUser});
}

class _LibraryTab extends StatefulWidget {
  const _LibraryTab();

  @override
  State<_LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<_LibraryTab> {
  CactusProgress _progress = const CactusProgress(CactusStage.idle);
  String? _error;
  final List<_ChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool get _busy =>
      _progress.stage == CactusStage.loading ||
      _progress.stage == CactusStage.generating;

  Future<void> _transcribeWhisper() async {
    setState(() => _error = null);
    try {
      final docs = await getApplicationDocumentsDirectory();
      const filename = 'single_person_16k_mono.wav';
      final candidates = [
        '${docs.path}/$filename',
        '${docs.parent.path}/$filename',
      ];
      final audioPath = candidates.firstWhere(
        (p) => File(p).existsSync(),
        orElse: () => throw Exception('Audio file not found. Tried:\n${candidates.join('\n')}'),
      );
      final result = await CactusService.instance.transcribeWhisper(
        audioPath,
        (p) { if (mounted) setState(() => _progress = p); },
      );
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(text: '[Whisper] $result', isUser: false));
        _progress = const CactusProgress(CactusStage.ready);
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _progress = const CactusProgress(CactusStage.error);
      });
    }
  }

  Future<void> _transcribeAudio() async {
    setState(() => _error = null);
    try {
      final docs = await getApplicationDocumentsDirectory();
      const filename = 'single_person_16k_mono.wav';
      final candidates = [
        '${docs.path}/$filename',
        '${docs.parent.path}/$filename',
      ];
      final audioPath = candidates.firstWhere(
        (p) => File(p).existsSync(),
        orElse: () => throw Exception('Audio file not found. Tried:\n${candidates.join('\n')}'),
      );
      await CactusService.instance.transcribeAudioChunked(
        audioPath,
        (p) { if (mounted) setState(() => _progress = p); },
        (chunk, total, text) {
          if (!mounted) return;
          setState(() => _messages.add(
            _ChatMessage(text: '[Chunk $chunk/$total] $text', isUser: false),
          ));
          _scrollToBottom();
        },
      );
      if (!mounted) return;
      setState(() => _progress = const CactusProgress(CactusStage.ready));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _progress = const CactusProgress(CactusStage.error);
      });
    }
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    setState(() {
      _error = null;
      _messages.add(_ChatMessage(text: text.trim(), isUser: true));
    });
    _inputController.clear();
    _scrollToBottom();

    try {
      await CactusService.instance.init((p) {
        if (mounted) setState(() => _progress = p);
      });
      setState(() => _progress = const CactusProgress(CactusStage.generating, message: 'Generating…'));
      final result = await CactusService.instance.complete(text.trim());
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(text: result, isUser: false));
        _progress = const CactusProgress(CactusStage.ready);
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _progress = const CactusProgress(CactusStage.error);
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _sendMessage('Hello!'),
              icon: const Icon(Icons.waving_hand),
              label: const Text('Say hello to Gemma-4'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _transcribeAudio,
              icon: const Icon(Icons.mic),
              label: const Text('Transcribe Audio'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _transcribeWhisper,
              icon: const Icon(Icons.mic_external_on),
              label: const Text('Transcribe Audio (Whisper)'),
            ),
            const SizedBox(height: 8),
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 4),
              Text(
                '${_progress.stage.name}${_progress.message != null ? ' — ${_progress.message}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Text(
                        _busy
                            ? 'Loading the model weights and sending the Hello message...'
                            : 'Tap the button or type a message to start.',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        return Align(
                          alignment: msg.isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.75,
                            ),
                            decoration: BoxDecoration(
                              color: msg.isUser
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: SelectableText(
                              msg.text,
                              style: TextStyle(
                                color: msg.isUser
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : null,
                                fontFamily: 'Menlo',
                                fontSize: 13,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      hintText: 'Type a message…',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: _busy ? null : _sendMessage,
                    textInputAction: TextInputAction.send,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _sendMessage(_inputController.text),
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTab extends StatelessWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Settings'));
  }
}

class CallPage extends StatefulWidget {
  const CallPage({super.key});

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late final RtcEngine _engine;
  bool _joined = false;
  int? _remoteUid;
  bool _muted = false;
  bool _cameraOff = false;

  @override
  void initState() {
    super.initState();
    _initAgora();
  }

  Future<void> _initAgora() async {
    await [Permission.microphone, Permission.camera].request();

    _engine = createAgoraRtcEngine();
    await _engine.initialize(const RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));

    _engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        if (mounted) setState(() => _joined = true);
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        if (mounted) setState(() => _remoteUid = remoteUid);
      },
      onUserOffline: (connection, remoteUid, reason) {
        if (mounted && _remoteUid == remoteUid) {
          setState(() => _remoteUid = null);
        }
      },
    ));

    await _engine.enableVideo();
    await _engine.startPreview();
    await _engine.joinChannel(
      token: token,
      channelId: channelName,
      uid: 0,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );
  }

  @override
  void dispose() {
    _engine.leaveChannel();
    _engine.release();
    super.dispose();
  }

  Widget _remoteView() {
    if (_remoteUid == null) {
      return const Center(
        child: Text('Waiting for another user to join…',
            style: TextStyle(color: Colors.white70)),
      );
    }
    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: _engine,
        canvas: VideoCanvas(uid: _remoteUid),
        connection: const RtcConnection(channelId: channelName),
      ),
    );
  }

  Widget _localView() {
    if (!_joined) return const ColoredBox(color: Colors.black);
    return AgoraVideoView(
      controller: VideoViewController(
        rtcEngine: _engine,
        canvas: const VideoCanvas(uid: 0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _remoteView()),
          Positioned(
            top: 40,
            right: 16,
            width: 120,
            height: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _localView(),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _CircleButton(
                  icon: _muted ? Icons.mic_off : Icons.mic,
                  color: _muted ? Colors.red : Colors.white24,
                  onTap: () async {
                    await _engine.muteLocalAudioStream(!_muted);
                    setState(() => _muted = !_muted);
                  },
                ),
                _CircleButton(
                  icon: Icons.call_end,
                  color: Colors.red,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                _CircleButton(
                  icon: _cameraOff ? Icons.videocam_off : Icons.videocam,
                  color: _cameraOff ? Colors.red : Colors.white24,
                  onTap: () async {
                    await _engine.muteLocalVideoStream(!_cameraOff);
                    setState(() => _cameraOff = !_cameraOff);
                  },
                ),
                _CircleButton(
                  icon: Icons.cameraswitch,
                  color: Colors.white24,
                  onTap: () => _engine.switchCamera(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _CircleButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}
