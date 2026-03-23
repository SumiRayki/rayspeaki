import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/channel.dart';
import '../theme.dart';

/// 频道管理底部弹窗（Admin）
class ChannelAdminSheet extends StatelessWidget {
  final Channel channel;
  final Future<bool> Function(String name) onRename;
  final Future<bool> Function(String bg) onSetBackground;
  final Future<bool> Function(String password) onSetPassword;
  final Future<bool> Function() onDelete;

  const ChannelAdminSheet({
    super.key,
    required this.channel,
    required this.onRename,
    required this.onSetBackground,
    required this.onSetPassword,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 拖动条
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '管理 - ${channel.name}',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),

          _AdminOption(
            icon: Icons.edit,
            label: '重命名频道',
            onTap: () => _showRenameDialog(context),
          ),
          _AdminOption(
            icon: Icons.image,
            label: '更换背景',
            onTap: () => _pickBackground(context),
          ),
          _AdminOption(
            icon: Icons.lock,
            label: channel.hasPassword ? '修改密码' : '设置密码',
            onTap: () => _showPasswordDialog(context),
          ),
          if (channel.hasPassword)
            _AdminOption(
              icon: Icons.lock_open,
              label: '移除密码',
              onTap: () async {
                final ok = await onSetPassword('');
                if (ok && context.mounted) Navigator.pop(context);
              },
            ),
          _AdminOption(
            icon: Icons.delete_forever,
            label: '删除频道',
            color: AppTheme.error,
            onTap: () => _confirmDelete(context),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context) {
    final controller = TextEditingController(text: channel.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名频道'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '频道名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              final ok = await onRename(name);
              if (ok && context.mounted) Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickBackground(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 80,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final b64 = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      final ok = await onSetBackground(b64);
      if (ok && context.mounted) Navigator.pop(context);
    } catch (_) {}
  }

  void _showPasswordDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置频道密码'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新密码'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final pwd = controller.text.trim();
              if (pwd.isEmpty) return;
              Navigator.pop(ctx);
              final ok = await onSetPassword(pwd);
              if (ok && context.mounted) Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除频道'),
        content: Text('确定删除 "${channel.name}"？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await onDelete();
              if (ok && context.mounted) Navigator.pop(context);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

class _AdminOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _AdminOption({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.textPrimary;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: c, size: 22),
      title: Text(label, style: TextStyle(color: c, fontSize: 15)),
      onTap: onTap,
    );
  }
}
