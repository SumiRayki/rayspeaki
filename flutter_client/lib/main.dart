import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'services/api_service.dart';
import 'services/auth_service.dart';
import 'services/socket_service.dart';
import 'services/mediasoup_service.dart';
import 'providers/auth_provider.dart';
import 'providers/channel_provider.dart';
import 'providers/voice_provider.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

/// 全局信任自签名证书 — Socket.IO / WebSocket / HTTP 全部生效
class _TrustAllCertsOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (cert, host, port) => true;
  }
}

void main() async {
  HttpOverrides.global = _TrustAllCertsOverrides();
  WidgetsFlutterBinding.ensureInitialized();

  // 预初始化 SharedPreferences，避免首次调用阻塞
  await SharedPreferences.getInstance();

  // 沉浸状态栏
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.surface,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // 全局 services（单例）
  final apiService = ApiService();
  final authService = AuthService();
  final socketService = SocketService();
  final mediasoupService = MediasoupService(socketService);

  // 全局错误捕获 — 防止 native 层未捕获的异常导致闪退
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exception}');
  };

  runApp(
    MultiProvider(
      providers: [
        // Services
        Provider<ApiService>.value(value: apiService),
        Provider<AuthService>.value(value: authService),
        Provider<SocketService>.value(value: socketService),
        Provider<MediasoupService>.value(value: mediasoupService),

        // Providers (state management)
        ChangeNotifierProvider(
          create: (_) => AuthProvider(api: apiService, auth: authService),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              ChannelProvider(api: apiService, socket: socketService),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              VoiceProvider(socket: socketService, mediasoup: mediasoupService),
        ),
      ],
      child: const RaySpeakiApp(),
    ),
  );
}

class RaySpeakiApp extends StatelessWidget {
  const RaySpeakiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RaySpeaki',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const _EntryPoint(),
    );
  }
}

/// 入口判断：有 session 则恢复登录，否则显示登录页
class _EntryPoint extends StatefulWidget {
  const _EntryPoint();

  @override
  State<_EntryPoint> createState() => _EntryPointState();
}

class _EntryPointState extends State<_EntryPoint> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final auth = context.read<AuthProvider>();
    final restored = await auth.tryRestoreSession();

    if (mounted) {
      setState(() => _checking = false);
      if (restored) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppTheme.accent),
              SizedBox(height: 16),
              Text('正在连接...',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ],
          ),
        ),
      );
    }
    return const LoginScreen();
  }
}
