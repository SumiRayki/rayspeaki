import 'dart:convert';
import 'dart:io';
import '../config.dart';

class _RawResponse {
  final int statusCode;
  final String body;
  _RawResponse(this.statusCode, this.body);
}

/// REST API service — 所有 /api 请求走这里
class ApiService {
  String? _token;

  void setToken(String token) => _token = token;
  void clearToken() => _token = null;

  /// 创建一个信任自签名证书的 HttpClient
  static HttpClient createTrustingClient() {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    client.connectionTimeout = const Duration(seconds: 10);
    return client;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'X-Session-Token': _token!,
      };

  Future<_RawResponse> _get(String path) async {
    final ioClient = createTrustingClient();
    try {
      final request =
          await ioClient.getUrl(Uri.parse('${AppConfig.apiBase}$path'));
      _headers.forEach((k, v) => request.headers.set(k, v));
      final ioResponse = await request.close();
      final bytes = await ioResponse.fold<List<int>>(
          <int>[], (prev, chunk) => prev..addAll(chunk));
      final body = utf8.decode(bytes, allowMalformed: true);
      return _RawResponse(ioResponse.statusCode, body);
    } finally {
      ioClient.close();
    }
  }

  Future<_RawResponse> _post(String path, Map<String, dynamic> body) async {
    final ioClient = createTrustingClient();
    try {
      final request =
          await ioClient.postUrl(Uri.parse('${AppConfig.apiBase}$path'));
      _headers.forEach((k, v) => request.headers.set(k, v));
      request.write(jsonEncode(body));
      final ioResponse = await request.close();
      final bytes = await ioResponse.fold<List<int>>(
          <int>[], (prev, chunk) => prev..addAll(chunk));
      final respBody = utf8.decode(bytes, allowMalformed: true);
      return _RawResponse(ioResponse.statusCode, respBody);
    } finally {
      ioClient.close();
    }
  }

  Future<_RawResponse> _put(String path, Map<String, dynamic> body) async {
    final ioClient = createTrustingClient();
    try {
      final request =
          await ioClient.putUrl(Uri.parse('${AppConfig.apiBase}$path'));
      _headers.forEach((k, v) => request.headers.set(k, v));
      request.write(jsonEncode(body));
      final ioResponse = await request.close();
      final bytes = await ioResponse.fold<List<int>>(
          <int>[], (prev, chunk) => prev..addAll(chunk));
      final respBody = utf8.decode(bytes, allowMalformed: true);
      return _RawResponse(ioResponse.statusCode, respBody);
    } finally {
      ioClient.close();
    }
  }

  Future<_RawResponse> _delete(String path) async {
    final ioClient = createTrustingClient();
    try {
      final request =
          await ioClient.deleteUrl(Uri.parse('${AppConfig.apiBase}$path'));
      _headers.forEach((k, v) => request.headers.set(k, v));
      final ioResponse = await request.close();
      final bytes = await ioResponse.fold<List<int>>(
          <int>[], (prev, chunk) => prev..addAll(chunk));
      final body = utf8.decode(bytes, allowMalformed: true);
      return _RawResponse(ioResponse.statusCode, body);
    } finally {
      ioClient.close();
    }
  }

  // ─── Auth ───────────────────────────────────────────────

  Future<Map<String, dynamic>> login(String username, String password) async {
    final resp =
        await _post('/login', {'username': username, 'password': password});
    if (resp.statusCode != 200) {
      final msg = _parseError(resp);
      throw ApiException(msg);
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    _token = data['session'] as String;
    return data;
  }

  Future<void> logout() async {
    await _post('/logout', {});
    _token = null;
  }

  Future<Map<String, dynamic>> getMe() async {
    final resp = await _get('/me');
    if (resp.statusCode != 200) throw ApiException('获取用户信息失败');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ─── Channels ───────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getChannels() async {
    final resp = await _get('/channels');
    if (resp.statusCode != 200) throw ApiException('获取频道列表失败');
    final list = jsonDecode(resp.body) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createChannel(String name) async {
    final resp = await _post('/channels', {'name': name});
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw ApiException('创建频道失败');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> updateChannel(int id,
      {String? name, String? background, String? password}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (background != null) body['background'] = background;
    if (password != null) body['password'] = password;
    final resp = await _put('/channels/$id', body);
    if (resp.statusCode != 200) throw ApiException('更新频道失败');
  }

  Future<void> deleteChannel(int id) async {
    final resp = await _delete('/channels/$id');
    if (resp.statusCode != 200) throw ApiException('删除频道失败');
  }

  // ─── Avatar ─────────────────────────────────────────────

  Future<String> getAvatar(String username) async {
    final resp = await _get('/avatar?username=${Uri.encodeComponent(username)}');
    if (resp.statusCode != 200) return '';
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data['avatar'] as String? ?? '';
  }

  Future<void> updateAvatar(String base64Avatar) async {
    final resp = await _put('/avatar', {'avatar': base64Avatar});
    if (resp.statusCode != 200) throw ApiException('更新头像失败');
  }

  // ─── Downloads ──────────────────────────────────────────

  Future<Map<String, String>> getDownloads() async {
    final resp = await _get('/downloads');
    if (resp.statusCode != 200) return {};
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data.map((k, v) => MapEntry(k, v.toString()));
  }

  Future<void> updateDownloads(Map<String, String> links) async {
    final resp = await _put('/downloads', links);
    if (resp.statusCode != 200) throw ApiException('更新下载链接失败');
  }

  // ─── Helpers ────────────────────────────────────────────

  String _parseError(_RawResponse resp) {
    try {
      final data = jsonDecode(resp.body);
      return data['error']?.toString() ?? '请求失败 (${resp.statusCode})';
    } catch (_) {
      return '请求失败 (${resp.statusCode})';
    }
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}
