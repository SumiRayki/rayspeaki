import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../theme.dart';

/// 用户头像 — 支持 base64 图片和首字母回退
class AvatarWidget extends StatelessWidget {
  final String? avatar; // base64 data url
  final String name;
  final double size;
  final bool showSpeaking;
  final VoidCallback? onTap;

  const AvatarWidget({
    super.key,
    this.avatar,
    required this.name,
    this.size = 48,
    this.showSpeaking = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget content;

    final bytes = _decodeAvatar(avatar);
    if (bytes != null) {
      content = ClipOval(
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    } else {
      // 首字母
      final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
      content = Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.surfaceLight,
        ),
        alignment: Alignment.center,
        child: Text(
          letter,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: size * 0.4,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    // 说话指示器 — 外发光
    if (showSpeaking) {
      content = Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppTheme.speaking.withOpacity(0.6),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: content,
      );
    }

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: content);
    }
    return content;
  }

  static Uint8List? _decodeAvatar(String? avatar) {
    if (avatar == null || avatar.isEmpty) return null;
    try {
      // 格式: data:image/...;base64,xxxxx
      if (avatar.startsWith('data:')) {
        final comma = avatar.indexOf(',');
        if (comma == -1) return null;
        return base64Decode(avatar.substring(comma + 1));
      }
      return base64Decode(avatar);
    } catch (_) {
      return null;
    }
  }
}
