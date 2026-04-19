import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'call_transcriber.dart';
import 'library_tab.dart';

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
    LibraryTab(),
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
          NavigationDestination(icon: Icon(Icons.library_books), label: 'Library'),
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

class _LibraryTab extends StatefulWidget {
  const _LibraryTab();

  @override
  State<_LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<_LibraryTab> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    CallTranscriber.instance.addListener(_onTranscriberChanged);
  }

  @override
  void dispose() {
    CallTranscriber.instance.removeListener(_onTranscriberChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onTranscriberChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final transcriber = CallTranscriber.instance;
    final lines = transcriber.lines;
    final status = transcriber.status;
    final error = transcriber.error;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Call Transcript',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (lines.isNotEmpty)
                  TextButton.icon(
                    onPressed: transcriber.clear,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Clear'),
                  ),
              ],
            ),
            if (status != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  if (transcriber.isActive)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (transcriber.isActive) const SizedBox(width: 8),
                  Text(status, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 4),
              Text(
                error,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: lines.isEmpty
                  ? Center(
                      child: Text(
                        transcriber.isActive
                            ? 'Listening… transcript will appear here.'
                            : 'Start a call to see the transcript.',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: lines.length,
                      itemBuilder: (context, index) {
                        final line = lines[index];
                        final speaker = line.isMe ? 'Me' : 'Other';
                        final color = line.isMe
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.tertiary;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: RichText(
                            text: TextSpan(
                              style: Theme.of(context).textTheme.bodyMedium,
                              children: [
                                TextSpan(
                                  text: '$speaker: ',
                                  style: TextStyle(
                                    color: color,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                TextSpan(text: line.text),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
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
  AudioFrameObserver? _audioObserver;
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

    _audioObserver = AudioFrameObserver(
      onRecordAudioFrame: (channelId, audioFrame) {
        CallTranscriber.instance.addMyFrame(audioFrame.buffer);
      },
      onPlaybackAudioFrameBeforeMixing: (channelId, uid, audioFrame) {
        CallTranscriber.instance.addOtherFrame(audioFrame.buffer);
      },
    );
    _engine.getMediaEngine().registerAudioFrameObserver(_audioObserver!);
    await _engine.setRecordingAudioFrameParameters(
      sampleRate: CallTranscriber.sampleRate,
      channel: CallTranscriber.channels,
      mode: RawAudioFrameOpModeType.rawAudioFrameOpModeReadOnly,
      samplesPerCall: 1024,
    );
    await _engine.setPlaybackAudioFrameBeforeMixingParameters(
      sampleRate: CallTranscriber.sampleRate,
      channel: CallTranscriber.channels,
      samplesPerCall: 1024,
    );
    // Clear old transcript and begin capturing for this call.
    CallTranscriber.instance.clear();
    await CallTranscriber.instance.start();

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
    CallTranscriber.instance.stop();
    if (_audioObserver != null) {
      _engine.getMediaEngine().unregisterAudioFrameObserver(_audioObserver!);
    }
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
