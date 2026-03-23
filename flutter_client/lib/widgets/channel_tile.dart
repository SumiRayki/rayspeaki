import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../theme.dart';
import 'avatar_widget.dart';

/// 频道列表项
class ChannelTile extends StatelessWidget {
  final Channel channel;
  final bool isActive;
  final bool isAdmin;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  // 头像缓存回调
  final String Function(String identity)? getAvatar;

  const ChannelTile({
    super.key,
    required this.channel,
    this.isActive = false,
    this.isAdmin = false,
    required this.onTap,
    this.onLongPress,
    this.getAvatar,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: isActive
          ? AppTheme.accent.withOpacity(0.15)
          : AppTheme.surface,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.volume_up_rounded,
                    color: isActive ? AppTheme.accent : AppTheme.textSecondary,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      channel.name,
                      style: TextStyle(
                        color: isActive
                            ? AppTheme.accent
                            : AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (channel.hasPassword)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.lock_rounded,
                          color: AppTheme.textSecondary, size: 16),
                    ),
                  if (channel.members.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${channel.members.length}',
                          style: const TextStyle(
                            color: AppTheme.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              // 频道内成员预览
              if (channel.members.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: channel.members.map((m) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AvatarWidget(
                          name: m.identity,
                          avatar: getAvatar?.call(m.identity),
                          size: 20,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          m.identity,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
