import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../providers/auth_provider.dart';
import '../providers/channel_provider.dart';
import '../providers/voice_provider.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';
import '../theme.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/channel_admin_sheet.dart';
import '../widgets/channel_tile.dart';
import '../widgets/downloads_sheet.dart';
import '../widgets/online_users_sheet.dart';
import 'login_screen.dart';
import 'voice_room_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Map<String, String> _avatarCache = {};
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;

    final auth = context.read<AuthProvider>();
    final channelProv = context.read<ChannelProvider>();
    final voiceProv = context.read<VoiceProvider>();
    final socket = context.read<SocketService>();

    // 连接 Socket
    socket.connect(auth.token!);

    // 监听事件
    channelProv.listenSocket();
    voiceProv.listenSocket();

    // 等待认证完成，设置 self id
    socket.on('authenticated').listen((data) {
      if (data == null) return;
      voiceProv.setSelf(
        '', // socket id 会在 joinChannel 回调中获取
        auth.user!.identity,
      );
    });

    // 加载频道列表
    await channelProv.loadChannels();

    // 预加载头像
    _loadAvatars();
  }

  Future<void> _loadAvatars() async {
    final channelProv = context.read<ChannelProvider>();
    final api = context.read<ApiService>();
    final identities = <String>{};

    for (final ch in channelProv.channels) {
      for (final m in ch.members) {
        identities.add(m.identity);
      }
    }
    for (final u in channelProv.onlineUsers) {
      identities.add(u);
    }

    for (final name in identities) {
      if (!_avatarCache.containsKey(name)) {
        try {
          _avatarCache[name] = await api.getAvatar(name);
        } catch (_) {}
      }
    }
    if (mounted) setState(() {});
  }

  String _getAvatar(String identity) => _avatarCache[identity] ?? '';

  Future<void> _joinChannel(Channel channel) async {
    String? password;

    // 如果频道有密码且不是管理员，弹出密码输入
    final auth = context.read<AuthProvider>();
    if (channel.hasPassword && !auth.isAdmin) {
      password = await _showPasswordPrompt(channel.name);
      if (password == null) return; // 取消
    }

    final voiceProv = context.read<VoiceProvider>();
    final error = await voiceProv.joinChannel(
      channel.id,
      channel.name,
      password: password,
    );

    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const VoiceRoomScreen()),
      );
    }
  }

  Future<String?> _showPasswordPrompt(String channelName) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('输入 "$channelName" 的密码'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: '频道密码'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('加入'),
          ),
        ],
      ),
    );
  }

  void _showChannelAdmin(Channel channel) {
    final channelProv = context.read<ChannelProvider>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChannelAdminSheet(
        channel: channel,
        onRename: (name) => channelProv.renameChannel(channel.id, name),
        onSetBackground: (bg) =>
            channelProv.setChannelBackground(channel.id, bg),
        onSetPassword: (pwd) =>
            channelProv.setChannelPassword(channel.id, pwd),
        onDelete: () => channelProv.deleteChannel(channel.id),
      ),
    );
  }

  void _showCreateChannel() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建频道'),
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
              await context.read<ChannelProvider>().createChannel(name);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _showOnlineUsers() {
    final channelProv = context.read<ChannelProvider>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => OnlineUsersSheet(
        users: channelProv.onlineUsers,
        getAvatar: _getAvatar,
      ),
    );
  }

  void _showDownloads() async {
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    try {
      final links = await api.getDownloads();
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => DownloadsSheet(
          links: links,
          isAdmin: auth.isAdmin,
          onSave: auth.isAdmin ? (l) => api.updateDownloads(l) : null,
        ),
      );
    } catch (_) {}
  }

  void _showProfile() {
    final auth = context.read<AuthProvider>();
    showModalBottomSheet(
      context: context,
      builder: (_) => _ProfileSheet(
        auth: auth,
        onAvatarChanged: (base64) {
          _avatarCache[auth.user!.identity] = base64;
          setState(() {});
        },
        onLogout: () async {
          Navigator.pop(context); // close sheet
          await auth.logout();
          context.read<SocketService>().disconnect();
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final channelProv = context.watch<ChannelProvider>();
    final voiceProv = context.watch<VoiceProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('RaySpeaki'),
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: GestureDetector(
            onTap: _showProfile,
            child: AvatarWidget(
              name: auth.user?.identity ?? '',
              avatar: auth.user?.avatar,
              size: 36,
            ),
          ),
        ),
        actions: [
          // 在线用户
          IconButton(
            icon: Badge(
              label: Text('${channelProv.onlineUsers.length}'),
              backgroundColor: AppTheme.accent,
              child: const Icon(Icons.people_outline),
            ),
            onPressed: _showOnlineUsers,
          ),
          // 下载
          IconButton(
            icon: const Icon(Icons.download_outlined),
            onPressed: _showDownloads,
          ),
        ],
      ),
      body: Column(
        children: [
          // 当前正在的频道指示条
          if (voiceProv.inChannel)
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VoiceRoomScreen()),
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: AppTheme.accent.withOpacity(0.15),
                child: Row(
                  children: [
                    const Icon(Icons.volume_up, color: AppTheme.accent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '正在 ${voiceProv.currentChannelName} 中通话',
                        style: const TextStyle(
                          color: AppTheme.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios,
                        color: AppTheme.accent, size: 14),
                  ],
                ),
              ),
            ),

          // 频道列表
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await channelProv.loadChannels();
                await _loadAvatars();
              },
              child: channelProv.loading
                  ? const Center(
                      child: CircularProgressIndicator(color: AppTheme.accent),
                    )
                  : channelProv.error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline,
                                  color: AppTheme.error, size: 48),
                              const SizedBox(height: 12),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 32),
                                child: SelectableText(
                                  channelProv.error!,
                                  style: const TextStyle(
                                      color: AppTheme.error, fontSize: 13),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: () => channelProv.loadChannels(),
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      : channelProv.channels.isEmpty
                          ? const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.forum_outlined,
                                      color: AppTheme.textSecondary, size: 48),
                                  SizedBox(height: 12),
                                  Text('暂无频道',
                                      style: TextStyle(
                                          color: AppTheme.textSecondary)),
                                ],
                              ),
                            )
                          : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: channelProv.channels.length,
                      itemBuilder: (context, index) {
                        final channel = channelProv.channels[index];
                        return ChannelTile(
                          channel: channel,
                          isActive:
                              voiceProv.currentChannelId == channel.id,
                          isAdmin: auth.isAdmin,
                          getAvatar: _getAvatar,
                          onTap: () => _joinChannel(channel),
                          onLongPress:
                              auth.isAdmin ? () => _showChannelAdmin(channel) : null,
                        );
                      },
                    ),
            ),
          ),
        ],
      ),

      // Admin: 创建频道 FAB
      floatingActionButton: auth.isAdmin
          ? FloatingActionButton(
              backgroundColor: AppTheme.accent,
              onPressed: _showCreateChannel,
              child: const Icon(Icons.add, color: Colors.white),
            )
          : null,
    );
  }
}

/// 个人资料底部弹窗
class _ProfileSheet extends StatelessWidget {
  final AuthProvider auth;
  final ValueChanged<String> onAvatarChanged;
  final VoidCallback onLogout;

  const _ProfileSheet({
    required this.auth,
    required this.onAvatarChanged,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final user = auth.user!;
    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          const SizedBox(height: 24),

          // 头像（点击更换）
          GestureDetector(
            onTap: () => _pickAvatar(context),
            child: Stack(
              children: [
                AvatarWidget(
                  name: user.identity,
                  avatar: user.avatar,
                  size: 72,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: AppTheme.accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.edit, color: Colors.white, size: 14),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 用户名
          Text(
            user.identity,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),

          // 角色
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: user.isAdmin
                  ? AppTheme.accent.withOpacity(0.15)
                  : AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              user.isAdmin ? '管理员' : '成员',
              style: TextStyle(
                color: user.isAdmin ? AppTheme.accent : AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 32),

          // 登出
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onLogout,
              icon: const Icon(Icons.logout, color: AppTheme.error),
              label: const Text('退出登录',
                  style: TextStyle(color: AppTheme.error)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.error),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAvatar(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 80,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final b64 = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      await auth.updateAvatar(b64);
      onAvatarChanged(b64);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更换头像失败: $e')),
        );
      }
    }
  }
}
