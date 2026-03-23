import 'package:flutter/material.dart';
import '../theme.dart';

/// 下载链接管理弹窗
class DownloadsSheet extends StatefulWidget {
  final Map<String, String> links;
  final bool isAdmin;
  final Future<void> Function(Map<String, String>)? onSave;

  const DownloadsSheet({
    super.key,
    required this.links,
    this.isAdmin = false,
    this.onSave,
  });

  @override
  State<DownloadsSheet> createState() => _DownloadsSheetState();
}

class _DownloadsSheetState extends State<DownloadsSheet> {
  late Map<String, TextEditingController> _controllers;

  static const _platforms = [
    ('windows', 'Windows', Icons.desktop_windows),
    ('macos', 'macOS', Icons.laptop_mac),
    ('linux', 'Linux', Icons.computer),
    ('android', 'Android', Icons.phone_android),
    ('ios', 'iOS', Icons.phone_iphone),
  ];

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final (key, _, __) in _platforms)
        key: TextEditingController(text: widget.links[key] ?? ''),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
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
          const Text(
            '下载客户端',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: _platforms.map((p) {
                final (key, name, icon) = p;
                final url = widget.links[key] ?? '';

                if (widget.isAdmin) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Icon(icon, color: AppTheme.textSecondary, size: 20),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 60,
                          child: Text(name,
                              style: const TextStyle(
                                  color: AppTheme.textPrimary, fontSize: 13)),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _controllers[key],
                            style: const TextStyle(
                                color: AppTheme.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: '下载链接',
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                // 普通用户只显示有链接的平台
                if (url.isEmpty) return const SizedBox.shrink();
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(icon, color: AppTheme.accent),
                  title:
                      Text(name, style: const TextStyle(color: AppTheme.textPrimary)),
                  subtitle: Text(
                    url,
                    style:
                        const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing:
                      const Icon(Icons.open_in_new, color: AppTheme.accent, size: 18),
                  onTap: () {
                    // 打开链接 — 在实际应用中用 url_launcher
                  },
                );
              }).toList(),
            ),
          ),

          if (widget.isAdmin) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final links = <String, String>{};
                  for (final (key, _, __) in _platforms) {
                    final val = _controllers[key]!.text.trim();
                    if (val.isNotEmpty) links[key] = val;
                  }
                  await widget.onSave?.call(links);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
