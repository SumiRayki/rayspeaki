import 'package:flutter/material.dart';
import '../theme.dart';

/// 单个用户的音量调节弹窗
class VolumeSliderDialog extends StatefulWidget {
  final String peerName;
  final double initialVolume;
  final ValueChanged<double> onChanged;

  const VolumeSliderDialog({
    super.key,
    required this.peerName,
    required this.initialVolume,
    required this.onChanged,
  });

  @override
  State<VolumeSliderDialog> createState() => _VolumeSliderDialogState();
}

class _VolumeSliderDialogState extends State<VolumeSliderDialog> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.initialVolume;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        '调节 ${widget.peerName} 的音量',
        style: const TextStyle(fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.volume_mute, color: AppTheme.textSecondary, size: 20),
              Expanded(
                child: Slider(
                  value: _volume,
                  min: 0,
                  max: 1,
                  activeColor: AppTheme.accent,
                  inactiveColor: AppTheme.surfaceLight,
                  onChanged: (val) {
                    setState(() => _volume = val);
                    widget.onChanged(val);
                  },
                ),
              ),
              const Icon(Icons.volume_up, color: AppTheme.textSecondary, size: 20),
            ],
          ),
          Text(
            '${(_volume * 100).round()}%',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
