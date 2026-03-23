import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../models/peer.dart';
import '../theme.dart';
import 'avatar_widget.dart';

/// 语音房间中的成员卡片
class MemberCard extends StatelessWidget {
  final Peer peer;
  final bool isSelf;
  final String? avatar;
  final MediaStream? videoStream;
  final VoidCallback? onTap; // 调节音量

  const MemberCard({
    super.key,
    required this.peer,
    this.isSelf = false,
    this.avatar,
    this.videoStream,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isSelf ? null : onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: peer.isSpeaking
                ? AppTheme.speaking.withOpacity(0.6)
                : AppTheme.border,
            width: peer.isSpeaking ? 2 : 0.5,
          ),
          boxShadow: peer.isSpeaking
              ? [
                  BoxShadow(
                    color: AppTheme.speaking.withOpacity(0.2),
                    blurRadius: 12,
                    spreadRadius: 1,
                  )
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 视频或头像
            if (videoStream != null)
              Expanded(
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(15)),
                  child: RTCVideoView(
                    _createRenderer(videoStream!),
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    mirror: isSelf,
                  ),
                ),
              )
            else ...[
              const SizedBox(height: 16),
              AvatarWidget(
                name: peer.identity,
                avatar: avatar,
                size: 56,
                showSpeaking: peer.isSpeaking,
              ),
            ],

            const SizedBox(height: 8),

            // 用户名
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      peer.identity,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isSelf)
                    const Text(
                      ' (你)',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),

            // 状态图标
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (peer.hasAudio)
                    Icon(
                      Icons.mic,
                      size: 14,
                      color: peer.isSpeaking
                          ? AppTheme.speaking
                          : AppTheme.textSecondary,
                    )
                  else
                    const Icon(Icons.mic_off,
                        size: 14, color: AppTheme.error),
                  if (peer.hasVideo) ...[
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

  RTCVideoRenderer _createRenderer(MediaStream stream) {
    final renderer = RTCVideoRenderer();
    renderer.initialize().then((_) {
      renderer.srcObject = stream;
    });
    return renderer;
  }
}
