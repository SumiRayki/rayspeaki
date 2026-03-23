class AppConfig {
  static const String defaultServerUrl = 'http://localhost:4000';

  /// 当前使用的服务器地址，可在登录页修改
  static String serverUrl = defaultServerUrl;

  /// REST API base（Go API 走同域 /api）
  static String get apiBase => '$serverUrl/api';

  /// Socket.IO 连接地址（Node server 同域）
  static String get socketUrl => serverUrl;
}
