import 'package:flutter/material.dart';
import '../theme.dart';

/// 语音房间底部控制栏
class ControlDock extends StatelessWidget {
  final bool micEnabled;
  final bool camEnabled;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onAudioSettings;
  final VoidCallback onDisconnect;

  const ControlDock({
    super.key,
    required this.micEnabled,
    required this.camEnabled,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onAudioSettings,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: 12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 麦克风
          _DockButton(
            icon: micEnabled ? Icons.mic : Icons.mic_off,
            label: micEnabled ? '静音' : '开麦',
            color: micEnabled ? AppTheme.textPrimary : AppTheme.error,
            bgColor: micEnabled
                ? AppTheme.surfaceLight
                : AppTheme.error.withOpacity(0.15),
            onTap: onToggleMic,
          ),

          // 摄像头
          _DockButton(
            icon: camEnabled ? Icons.videocam : Icons.videocam_off,
            label: camEnabled ? '关闭' : '摄像头',
            color: camEnabled ? AppTheme.accent : AppTheme.textSecondary,
            bgColor: camEnabled
                ? AppTheme.accent.withOpacity(0.15)
                : AppTheme.surfaceLight,
            onTap: onToggleCamera,
          ),

          // 翻转摄像头
          if (camEnabled)
            _DockButton(
              icon: Icons.flip_camera_android,
              label: '翻转',
              color: AppTheme.textSecondary,
              bgColor: AppTheme.surfaceLight,
              onTap: onSwitchCamera,
            ),

          // 音频设置
          _DockButton(
            icon: Icons.headphones,
            label: '音频',
            color: AppTheme.textSecondary,
            bgColor: AppTheme.surfaceLight,
            onTap: onAudioSettings,
          ),

          // 断开连接
          _DockButton(
            icon: Icons.call_end,
            label: '断开',
            color: Colors.white,
            bgColor: AppTheme.error,
            onTap: onDisconnect,
          ),
        ],
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color bgColor;
  final VoidCallback onTap;

  const _DockButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.bgColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
