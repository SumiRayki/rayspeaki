import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../theme.dart';
import '../providers/auth_provider.dart';
import '../widgets/aurora_background.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _serverCtrl = TextEditingController(text: AppConfig.serverUrl);
  bool _showServerField = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  void _syncServerUrl() {
    final serverUrl = _serverCtrl.text.trim();
    if (serverUrl.isNotEmpty) {
      AppConfig.serverUrl = serverUrl;
    }
  }

  Future<void> _login() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text.trim();
    if (username.isEmpty || password.isEmpty) return;

    _syncServerUrl();

    final auth = context.read<AuthProvider>();
    auth.clearError();

    final success = await auth.login(username, password);
    if (success && mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: Text(
                            'R',
                            style: TextStyle(
                              color: AppTheme.accent,
                              fontSize: 40,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'RaySpeaki',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '语音聊天',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 40),

                      // 登录卡片
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: AppTheme.surface.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppTheme.border.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Column(
                          children: [
                            // 用户名
                            TextField(
                              controller: _usernameCtrl,
                              style: const TextStyle(
                                  color: AppTheme.textPrimary),
                              decoration: const InputDecoration(
                                hintText: '用户名',
                                prefixIcon: Icon(Icons.person_outline,
                                    color: AppTheme.textSecondary),
                              ),
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 16),

                            // 密码
                            TextField(
                              controller: _passwordCtrl,
                              obscureText: _obscurePassword,
                              style: const TextStyle(
                                  color: AppTheme.textPrimary),
                              decoration: InputDecoration(
                                hintText: '密码',
                                prefixIcon: const Icon(Icons.lock_outline,
                                    color: AppTheme.textSecondary),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    color: AppTheme.textSecondary,
                                    size: 20,
                                  ),
                                  onPressed: () => setState(() =>
                                      _obscurePassword = !_obscurePassword),
                                ),
                              ),
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _login(),
                            ),

                            // 服务器地址
                            const SizedBox(height: 8),
                            GestureDetector(
                              onTap: () => setState(
                                  () => _showServerField = !_showServerField),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text(
                                    '服务器地址',
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Icon(
                                    _showServerField
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    color: AppTheme.textSecondary,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                            if (_showServerField) ...[
                              const SizedBox(height: 8),
                              TextField(
                                controller: _serverCtrl,
                                style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 13),
                                decoration: const InputDecoration(
                                  hintText: 'https://server:port',
                                  prefixIcon: Icon(Icons.dns_outlined,
                                      color: AppTheme.textSecondary),
                                  isDense: true,
                                ),
                              ),
                            ],

                            const SizedBox(height: 24),

                            // 错误提示
                            if (auth.error != null) ...[
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppTheme.error.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(Icons.error_outline,
                                        color: AppTheme.error, size: 18),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: SelectableText(
                                        auth.error!,
                                        style: const TextStyle(
                                            color: AppTheme.error,
                                            fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            // 登录按钮
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: ElevatedButton(
                                onPressed: auth.loading ? null : _login,
                                child: auth.loading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text('登录'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
