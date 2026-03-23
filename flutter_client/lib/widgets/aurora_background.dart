import 'dart:math';
import 'package:flutter/material.dart';

/// 登录页极光渐变动画背景
class AuroraBackground extends StatefulWidget {
  final Widget child;

  const AuroraBackground({super.key, required this.child});

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value;
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(sin(t * 2 * pi) * 0.5, -1),
              end: Alignment(cos(t * 2 * pi) * 0.5, 1),
              colors: [
                const Color(0xFF0a0a0f),
                Color.lerp(
                    const Color(0xFF1a0a2e),
                    const Color(0xFF0a1a2e),
                    (sin(t * 2 * pi) + 1) / 2)!,
                Color.lerp(
                    const Color(0xFF2a1a4e),
                    const Color(0xFF1a2a4e),
                    (cos(t * 2 * pi) + 1) / 2)!,
                const Color(0xFF0a0a0f),
              ],
              stops: [
                0.0,
                0.3 + sin(t * 2 * pi) * 0.1,
                0.7 + cos(t * 2 * pi) * 0.1,
                1.0,
              ],
            ),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
