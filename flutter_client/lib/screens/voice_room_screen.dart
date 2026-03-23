import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../models/peer.dart';
import '../providers/auth_provider.dart';
import '../providers/voice_provider.dart';
import '../services/api_service.dart';
import '../theme.dart';
import '../widgets/audio_settings_sheet.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/control_dock.dart';
import '../widgets/volume_slider_dialog.dart';

class VoiceRoomScreen extends StatefulWidget {
  const VoiceRoomScreen({super.key});

  @override
  State<VoiceRoomScreen> createState() => _VoiceRoomScreenState();
}

class _VoiceRoomScreenState extends State<VoiceRoomScreen> {
  final Map<String, String> _avatarCache = {};
  final Map<String, RTCVideoRenderer> _renderers = {};
  bool _voiceInitStarted = false;
  bool _leaving = false;

  // 全屏查看某个人的视频
  String? _fullscreenPeerId;

  @override
  void initState() {
    super.initState();
    _loadAvatars();
    // 延迟初始化语音引擎，确保界面先渲染
    WidgetsBinding.instance.addPostFrameCallback((_) => _initVoice());
  }

  Future<void> _initVoice() async {
    if (_voiceInitStarted) return;
    _voiceInitStarted = true;
    final voiceProv = context.read<VoiceProvider>();
    await voiceProv.initVoice();
  }

  @override
  void dispose() {
    for (final r in _renderers.values) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAvatars() async {
    final voiceProv = context.read<VoiceProvider>();
    final api = context.read<ApiService>();

    for (final peer in voiceProv.peers.values) {
      if (!_avatarCache.containsKey(peer.identity)) {
        try {
          _avatarCache[peer.identity] = await api.getAvatar(peer.identity);
        } catch (_) {}
      }
    }
    if (mounted) setState(() {});
  }

  RTCVideoRenderer _getOrCreateRenderer(String peerId, MediaStream stream) {
    if (_renderers.containsKey(peerId)) {
      return _renderers[peerId]!;
    }
    final renderer = RTCVideoRenderer();
    renderer.initialize().then((_) {
      renderer.srcObject = stream;
    });
    _renderers[peerId] = renderer;
    return renderer;
  }

  void _showVolumeSlider(Peer peer) {
    final voiceProv = context.read<VoiceProvider>();
    showDialog(
      context: context,
      builder: (_) => VolumeSliderDialog(
        peerName: peer.identity,
        initialVolume: voiceProv.getPeerVolume(peer.id),
        onChanged: (vol) => voiceProv.setPeerVolume(peer.id, vol),
      ),
    );
  }

  void _showAudioSettings() {
    showModalBottomSheet(
      context: context,
      builder: (_) => const AudioSettingsSheet(),
    );
  }

  Future<void> _disconnect() async {
    if (_leaving) return;
    _leaving = true;
    final voiceProv = context.read<VoiceProvider>();
    await voiceProv.leaveChannel();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final voiceProv = context.watch<VoiceProvider>();
    final auth = context.watch<AuthProvider>();

    if (!voiceProv.inChannel && !_leaving) {
      // 被服务端踢出等情况，返回上一页
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_leaving) {
          _leaving = true;
          Navigator.pop(context);
        }
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!voiceProv.inChannel && _leaving) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // 构建成员列表：自己 + peers
    final allMembers = <_MemberEntry>[];

    // 自己
    allMembers.add(_MemberEntry(
      peerId: '__self__',
      identity: auth.user?.identity ?? '',
      isSelf: true,
      avatar: auth.user?.avatar ?? '',
      hasAudio: voiceProv.micEnabled,
      hasVideo: voiceProv.camEnabled,
      isSpeaking: false,
      videoStream: voiceProv.localCamStream,
    ));

    // 远端 peers
    for (final peer in voiceProv.peers.values) {
      allMembers.add(_MemberEntry(
        peerId: peer.id,
        identity: peer.identity,
        isSelf: false,
        avatar: _avatarCache[peer.identity] ?? '',
        hasAudio: peer.hasAudio,
        hasVideo: peer.hasVideo,
        isSpeaking: peer.isSpeaking,
        videoStream: voiceProv.remoteVideoStreams[peer.id],
      ));
    }

    // 全屏视频视图
    if (_fullscreenPeerId != null) {
      final stream = voiceProv.remoteVideoStreams[_fullscreenPeerId!];
      if (stream != null) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            onTap: () => setState(() => _fullscreenPeerId = null),
            child: Center(
              child: RTCVideoView(
                _getOrCreateRenderer(_fullscreenPeerId!, stream),
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            ),
          ),
        );
      } else {
        _fullscreenPeerId = null;
      }
    }

    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.volume_up, size: 18, color: AppTheme.accent),
              const SizedBox(width: 6),
              Text(voiceProv.currentChannelName ?? ''),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
            tooltip: '返回（保持通话）',
          ),
        ),
        body: Column(
          children: [
            // 语音引擎状态
            if (voiceProv.voiceError != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: AppTheme.error.withOpacity(0.15),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: AppTheme.error, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        voiceProv.voiceError!,
                        style: const TextStyle(
                            color: AppTheme.error, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        _voiceInitStarted = false;
                        _initVoice();
                      },
                      child: const Text('重试',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              )
            else if (voiceProv.voiceStep.isNotEmpty &&
                voiceProv.voiceStep != '语音已连接')
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: AppTheme.accent.withOpacity(0.1),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      voiceProv.voiceStep,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),

            // 成员网格
            Expanded(
              child: allMembers.isEmpty
                  ? const Center(
                      child: Text('频道为空',
                          style: TextStyle(color: AppTheme.textSecondary)),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount:
                            MediaQuery.of(context).size.width > 600 ? 4 : 2,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 0.85,
                      ),
                      itemCount: allMembers.length,
                      itemBuilder: (context, index) {
                        final m = allMembers[index];
                        return _buildMemberCard(m);
                      },
                    ),
            ),

            // 底部控制栏
            ControlDock(
              micEnabled: voiceProv.micEnabled,
              camEnabled: voiceProv.camEnabled,
              onToggleMic: () => voiceProv.toggleMic(),
              onToggleCamera: () => voiceProv.toggleCamera(),
              onSwitchCamera: () => voiceProv.switchCamera(),
              onAudioSettings: _showAudioSettings,
              onDisconnect: _disconnect,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemberCard(_MemberEntry m) {
    final hasVideo = m.videoStream != null;

    return GestureDetector(
      onTap: m.isSelf
          ? null
          : () {
              // 如果有视频，点击进入全屏；否则调节音量
              if (hasVideo) {
                setState(() => _fullscreenPeerId = m.peerId);
              } else {
                _showVolumeSlider(Peer(
                  id: m.peerId,
                  identity: m.identity,
                ));
              }
            },
      onLongPress: m.isSelf || !hasVideo
          ? null
          : () => _showVolumeSlider(Peer(
                id: m.peerId,
                identity: m.identity,
              )),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: m.isSpeaking
                ? AppTheme.speaking.withOpacity(0.6)
                : AppTheme.border,
            width: m.isSpeaking ? 2 : 0.5,
          ),
          boxShadow: m.isSpeaking
              ? [
                  BoxShadow(
                    color: AppTheme.speaking.withOpacity(0.2),
                    blurRadius: 12,
                  )
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 视频或头像
            if (hasVideo)
              Expanded(
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(15)),
                  child: RTCVideoView(
                    _getOrCreateRenderer(m.peerId, m.videoStream!),
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    mirror: m.isSelf,
                  ),
                ),
              )
            else ...[
              const SizedBox(height: 16),
              AvatarWidget(
                name: m.identity,
                avatar: m.avatar,
                size: 56,
                showSpeaking: m.isSpeaking,
              ),
            ],

            const SizedBox(height: 8),

            // 名字
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      m.identity,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (m.isSelf)
                    const Text(' (你)',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 11)),
                ],
              ),
            ),

            // 状态图标
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (m.hasAudio)
                    Icon(Icons.mic,
                        size: 14,
                        color: m.isSpeaking
                            ? AppTheme.speaking
                            : AppTheme.textSecondary)
                  else
                    const Icon(Icons.mic_off,
                        size: 14, color: AppTheme.error),
                  if (m.hasVideo) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.videocam,
                        size: 14, color: AppTheme.accent),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberEntry {
  final String peerId;
  final String identity;
  final bool isSelf;
  final String avatar;
  final bool hasAudio;
  final bool hasVideo;
  final bool isSpeaking;
  final MediaStream? videoStream;

  _MemberEntry({
    required this.peerId,
    required this.identity,
    required this.isSelf,
    required this.avatar,
    required this.hasAudio,
    required this.hasVideo,
    required this.isSpeaking,
    this.videoStream,
  });
}
