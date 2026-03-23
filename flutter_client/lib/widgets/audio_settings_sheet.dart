import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../theme.dart';

/// 音频设置底部弹窗 — 输入/输出设备选择 + 降噪开关
class AudioSettingsSheet extends StatefulWidget {
  const AudioSettingsSheet({super.key});

  @override
  State<AudioSettingsSheet> createState() => _AudioSettingsSheetState();
}

class _AudioSettingsSheetState extends State<AudioSettingsSheet> {
  List<MediaDeviceInfo> _audioInputs = [];
  List<MediaDeviceInfo> _audioOutputs = [];
  String? _selectedInput;
  String? _selectedOutput;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      setState(() {
        _audioInputs =
            devices.where((d) => d.kind == 'audioinput').toList();
        _audioOutputs =
            devices.where((d) => d.kind == 'audiooutput').toList();
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
          const SizedBox(height: 20),

          const Text(
            '音频设置',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 20),

          // 输入设备
          const Text('输入设备（麦克风）',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border),
            ),
            child: DropdownButton<String>(
              value: _selectedInput,
              isExpanded: true,
              dropdownColor: AppTheme.surfaceLight,
              underline: const SizedBox(),
              hint: const Text('默认设备',
                  style: TextStyle(color: AppTheme.textSecondary)),
              items: _audioInputs
                  .map((d) => DropdownMenuItem(
                        value: d.deviceId,
                        child: Text(
                          d.label.isNotEmpty ? d.label : '麦克风 ${d.deviceId.substring(0, 8)}',
                          style: const TextStyle(color: AppTheme.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: (val) {
                setState(() => _selectedInput = val);
                // TODO: 切换音频输入设备
              },
            ),
          ),
          const SizedBox(height: 16),

          // 输出设备
          const Text('输出设备（扬声器）',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border),
            ),
            child: DropdownButton<String>(
              value: _selectedOutput,
              isExpanded: true,
              dropdownColor: AppTheme.surfaceLight,
              underline: const SizedBox(),
              hint: const Text('默认设备',
                  style: TextStyle(color: AppTheme.textSecondary)),
              items: _audioOutputs
                  .map((d) => DropdownMenuItem(
                        value: d.deviceId,
                        child: Text(
                          d.label.isNotEmpty ? d.label : '扬声器 ${d.deviceId.substring(0, 8)}',
                          style: const TextStyle(color: AppTheme.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: (val) {
                setState(() => _selectedOutput = val);
                // TODO: 切换音频输出设备
              },
            ),
          ),
          const SizedBox(height: 16),

          // 提示
          const Text(
            '提示：WebRTC 内置降噪、回声消除和自动增益已默认开启',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
