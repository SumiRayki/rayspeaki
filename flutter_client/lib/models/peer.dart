/// 语音房间内的对端用户
class Peer {
  final String id; // socket id
  final String identity;
  String avatar;
  bool isSpeaking;
  double volume; // 0.0 ~ 1.0
  final Map<String, ProducerInfo> producers; // producerId → info

  Peer({
    required this.id,
    required this.identity,
    this.avatar = '',
    this.isSpeaking = false,
    this.volume = 1.0,
    Map<String, ProducerInfo>? producers,
  }) : producers = producers ?? {};

  bool get hasAudio =>
      producers.values.any((p) => p.kind == 'audio');

  bool get hasVideo =>
      producers.values.any((p) => p.kind == 'video');

  bool get hasScreenShare =>
      producers.values.any((p) => p.kind == 'video' && p.source == 'screen');
}

class ProducerInfo {
  final String id;
  final String kind; // 'audio' | 'video'
  final Map<String, dynamic> appData;

  ProducerInfo({
    required this.id,
    required this.kind,
    this.appData = const {},
  });

  String get source => appData['source'] as String? ?? '';
}
