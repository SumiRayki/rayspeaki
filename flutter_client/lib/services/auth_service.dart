import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const _keyToken = 'session_token';
  static const _keyIdentity = 'identity';
  static const _keyRole = 'role';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get prefs async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<void> saveSession({
    required String token,
    required String identity,
    required String role,
  }) async {
    final p = await prefs;
    await p.setString(_keyToken, token);
    await p.setString(_keyIdentity, identity);
    await p.setString(_keyRole, role);
  }

  Future<String?> getToken() async => (await prefs).getString(_keyToken);
  Future<String?> getIdentity() async => (await prefs).getString(_keyIdentity);
  Future<String?> getRole() async => (await prefs).getString(_keyRole);

  Future<void> clearSession() async {
    final p = await prefs;
    await p.remove(_keyToken);
    await p.remove(_keyIdentity);
    await p.remove(_keyRole);
  }

  Future<bool> hasSession() async => (await getToken()) != null;
}
