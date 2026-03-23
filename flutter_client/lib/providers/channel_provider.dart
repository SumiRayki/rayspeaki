import 'dart:async';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';

class ChannelProvider extends ChangeNotifier {
  final ApiService api;
  final SocketService socket;

  List<Channel> _channels = [];
  List<String> _onlineUsers = [];
  final List<StreamSubscription> _subs = [];

  List<Channel> get channels => _channels;
  List<String> get onlineUsers => _onlineUsers;

  ChannelProvider({required this.api, required this.socket});

  bool _loading = false;
  String? _error;

  bool get loading => _loading;
  String? get error => _error;

  /// 加载频道列表（REST）
  Future<void> loadChannels() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final list = await api.getChannels();
      _channels = list.map((j) => Channel.fromJson(j)).toList();
      _error = null;
    } catch (e) {
      _error = '加载频道失败: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 开始监听 Socket 事件
  void listenSocket() {
    _subs.add(socket.on('initialState').listen((data) {
      if (data == null) return;
      // 解析频道成员
      final channelMembers = data['channelMembers'] as Map<String, dynamic>?;
      if (channelMembers != null) {
        for (final entry in channelMembers.entries) {
          final chId = int.tryParse(entry.key);
          if (chId == null) continue;
          final ch = _findChannel(chId);
          if (ch != null) {
            ch.members = (entry.value as List)
                .map((m) => ChannelMember.fromJson(m as Map<String, dynamic>))
                .toList();
          }
        }
      }
      // 解析在线用户
      final users = data['onlineUsers'] as List?;
      if (users != null) {
        _onlineUsers =
            users.map((u) => (u as Map<String, dynamic>)['identity'] as String).toList();
      }
      notifyListeners();
    }));

    _subs.add(socket.on('channelMembersUpdated').listen((data) {
      if (data == null) return;
      final chId = data['channelId'];
      final id = chId is int ? chId : int.tryParse(chId.toString());
      if (id == null) return;
      final ch = _findChannel(id);
      if (ch != null) {
        ch.members = (data['members'] as List)
            .map((m) => ChannelMember.fromJson(m as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    }));

    _subs.add(socket.on('onlineUsersUpdated').listen((data) {
      if (data == null) return;
      final users = data['users'] as List?;
      if (users != null) {
        _onlineUsers =
            users.map((u) => (u as Map<String, dynamic>)['identity'] as String).toList();
        notifyListeners();
      }
    }));
  }

  Channel? _findChannel(int id) {
    try {
      return _channels.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  Channel? getChannel(int id) => _findChannel(id);

  int getMemberCount(int channelId) {
    return _findChannel(channelId)?.members.length ?? 0;
  }

  /// Admin: 创建频道
  Future<Channel?> createChannel(String name) async {
    try {
      final data = await api.createChannel(name);
      final ch = Channel.fromJson(data);
      _channels.add(ch);
      notifyListeners();
      return ch;
    } catch (_) {
      return null;
    }
  }

  /// Admin: 重命名频道
  Future<bool> renameChannel(int id, String name) async {
    try {
      await api.updateChannel(id, name: name);
      _findChannel(id)?.name = name;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Admin: 设置频道背景
  Future<bool> setChannelBackground(int id, String bg) async {
    try {
      await api.updateChannel(id, background: bg);
      _findChannel(id)?.background = bg;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Admin: 设置频道密码
  Future<bool> setChannelPassword(int id, String password) async {
    try {
      await api.updateChannel(id, password: password);
      _findChannel(id)?.hasPassword = password.isNotEmpty;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Admin: 删除频道
  Future<bool> deleteChannel(int id) async {
    try {
      await api.deleteChannel(id);
      _channels.removeWhere((c) => c.id == id);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    super.dispose();
  }
}
