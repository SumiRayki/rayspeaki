import 'package:flutter/material.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  final ApiService api;
  final AuthService auth;

  User? _user;
  String? _token;
  bool _loading = false;
  String? _error;

  User? get user => _user;
  String? get token => _token;
  bool get isLoggedIn => _user != null && _token != null;
  bool get isAdmin => _user?.isAdmin ?? false;
  bool get loading => _loading;
  String? get error => _error;

  AuthProvider({required this.api, required this.auth});

  /// 尝试恢复保存的 session
  Future<bool> tryRestoreSession() async {
    final savedToken = await auth.getToken();
    if (savedToken == null) return false;

    api.setToken(savedToken);
    try {
      final data = await api.getMe();
      _token = savedToken;
      _user = User.fromJson(data);
      notifyListeners();
      return true;
    } catch (_) {
      await auth.clearSession();
      api.clearToken();
      return false;
    }
  }

  /// 登录
  Future<bool> login(String username, String password) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final data = await api.login(username, password);
      _token = data['session'] as String;
      _user = User(
        identity: data['identity'] as String,
        role: data['role'] as String,
      );

      await auth.saveSession(
        token: _token!,
        identity: _user!.identity,
        role: _user!.role,
      );

      // 加载头像
      try {
        _user!.avatar = await api.getAvatar(_user!.identity);
      } catch (_) {}

      _loading = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      _loading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _error = '连接服务器失败: $e';
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  /// 登出
  Future<void> logout() async {
    try {
      await api.logout();
    } catch (_) {}
    _user = null;
    _token = null;
    await auth.clearSession();
    api.clearToken();
    notifyListeners();
  }

  /// 更新头像
  Future<void> updateAvatar(String base64) async {
    await api.updateAvatar(base64);
    _user?.avatar = base64;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
