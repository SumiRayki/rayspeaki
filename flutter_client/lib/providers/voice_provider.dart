import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/peer.dart';
import '../services/socket_service.dart';
import '../services/mediasoup_service.dart';

/// 语音房间状态管理
class VoiceProvider extends ChangeNotifier {
  final SocketService socket;
  final MediasoupService mediasoup;

  int? _currentChannelId;
  String? _currentChannelName;
  final Map<String, Peer> _peers = {};
  String? _selfId; // 自己的 socket id
  bool _joining = false;
  String? _voiceError; // 语音引擎错误信息
  String _voiceStep = ''; // 当前初始化步骤

  // 远端视频流 peerId → MediaStream
  final Map<String, MediaStream> _remoteVideoStreams = {};
  // 远端音频流 peerId → MediaStream
  final Map<String, MediaStream> _remoteAudioStreams = {};

  // 每个 peer 的音量设置 peerId → volume (0.0~1.0)
  final Map<String, double> _peerVolumes = {};

  final List<StreamSubscription> _subs = [];

  int? get currentChannelId => _currentChannelId;
  String? get currentChannelName => _currentChannelName;
  bool get inChannel => _currentChannelId != null;
  bool get joining => _joining;
  String? get voiceError => _voiceError;
  String get voiceStep => _voiceStep;
  bool get micEnabled => mediasoup.micEnabled;
  bool get camEnabled => mediasoup.camEnabled;
  MediaStream? get localCamStream => mediasoup.localCamStream;
  Map<String, Peer> get peers => Map.unmodifiable(_peers);
  Map<String, MediaStream> get remoteVideoStreams =>
      Map.unmodifiable(_remoteVideoStreams);

  VoiceProvider({required this.socket, required this.mediasoup});

  void setSelf(String id, String identity) {
    _selfId = id;
  }

  double getPeerVolume(String peerId) => _peerVolumes[peerId] ?? 1.0;

  void setPeerVolume(String peerId, double vol) {
    _peerVolumes[peerId] = vol.clamp(0.0, 1.0);
    final stream = _remoteAudioStreams[peerId];
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = vol > 0;
      }
    }
    notifyListeners();
  }

  /// 开始监听 Socket 事件
  void listenSocket() {
    _subs.add(socket.on('peerJoined').listen((data) {
      if (data == null || _currentChannelId == null) return;
      final peerId = data['id'] as String;
      final identity = data['identity'] as String;
      if (peerId == _selfId) return;
      _peers[peerId] = Peer(id: peerId, identity: identity);
      notifyListeners();
    }));

    _subs.add(socket.on('peerLeft').listen((data) {
      if (data == null) return;
      final peerId = data['id'] as String;
      _peers.remove(peerId);
      _remoteVideoStreams.remove(peerId);
      _remoteAudioStreams.remove(peerId);
      notifyListeners();
    }));

    _subs.add(socket.on('newProducer').listen((data) async {
      if (data == null || _currentChannelId == null) return;
      final peerId = data['peerId'] as String;
      final producerId = data['producerId'] as String;
      final kind = data['kind'] as String;
      final appData = (data['appData'] as Map<String, dynamic>?) ?? {};

      debugPrint('[VoiceProvider] newProducer: peerId=$peerId kind=$kind appData=$appData');

      _peers[peerId]?.producers[producerId] = ProducerInfo(
        id: producerId,
        kind: kind,
        appData: appData,
      );

      try {
        await mediasoup.consume(peerId, producerId, kind);
      } catch (e) {
        debugPrint('[VoiceProvider] consume failed: $e');
      }
      notifyListeners();
    }));

    _subs.add(socket.on('producerClosed').listen((data) {
      if (data == null) return;
      final peerId = data['peerId'] as String;
      final producerId = data['producerId'] as String;
      _peers[peerId]?.producers.remove(producerId);

      if (!(_peers[peerId]?.hasVideo ?? false)) {
        _remoteVideoStreams.remove(peerId);
      }
      notifyListeners();
    }));

    // mediasoup consumer 回调 — 收到远端音视频流
    _subs.add(mediasoup.onConsumer.listen((event) {
      final consumer = event.consumer;
      final peerId = event.peerId;
      final stream = consumer.stream;
      final kind = consumer.kind;

      debugPrint('[VoiceProvider] onConsumer: peerId=$peerId kind=$kind stream=${stream?.id} videoTracks=${stream?.getVideoTracks().length} audioTracks=${stream?.getAudioTracks().length}');

      if (stream == null) {
        debugPrint('[VoiceProvider] onConsumer: stream is null, skipping');
        return;
      }
      if (kind == 'audio') {
        _remoteAudioStreams[peerId] = stream;
      } else if (kind == 'video') {
        _remoteVideoStreams[peerId] = stream;
        notifyListeners();
      }
    }));
  }

  /// 加入频道（仅 socket 信令，不初始化语音）
  Future<String?> joinChannel(int channelId, String channelName,
      {String? password}) async {
    if (_joining) return '正在加入中';
    _joining = true;
    _voiceError = null;
    notifyListeners();

    try {
      if (_currentChannelId != null) {
        await leaveChannel();
      }

      final rawResp = await socket.emitAsync('joinChannel', {
        'channelId': channelId.toString(),
        if (password != null && password.isNotEmpty) 'password': password,
      });

      if (rawResp is! Map<String, dynamic>) {
        _joining = false;
        notifyListeners();
        return '服务器返回格式异常';
      }
      final resp = rawResp;

      if (resp['error'] != null) {
        _joining = false;
        notifyListeners();
        return resp['error'] as String;
      }

      _currentChannelId = channelId;
      _currentChannelName = channelName;

      final existingPeers = resp['peers'] as List? ?? [];
      for (final p in existingPeers) {
        final peerData = p as Map<String, dynamic>;
        final peerId = peerData['id'] as String;
        if (peerId == _selfId) continue;

        final peer = Peer(
          id: peerId,
          identity: peerData['identity'] as String,
        );

        final producers = peerData['producers'] as List? ?? [];
        for (final prod in producers) {
          final prodData = prod as Map<String, dynamic>;
          peer.producers[prodData['id'] as String] = ProducerInfo(
            id: prodData['id'] as String,
            kind: prodData['kind'] as String,
            appData: (prodData['appData'] as Map<String, dynamic>?) ?? {},
          );
        }
        _peers[peerId] = peer;
      }

      _joining = false;
      notifyListeners();
      return null; // 成功加入频道
    } catch (e) {
      _joining = false;
      _currentChannelId = null;
      _currentChannelName = null;
      _peers.clear();
      notifyListeners();
      return '加入频道失败: $e';
    }
  }

  /// 初始化语音引擎（在进入房间界面后调用）
  Future<void> initVoice() async {
    _voiceError = null;
    _voiceStep = '1/6 请求麦克风权限...';
    notifyListeners();

    try {
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        _voiceError = '需要麦克风权限';
        notifyListeners();
        return;
      }
    } catch (e) {
      _voiceError = '步骤1 权限请求失败: $e';
      notifyListeners();
      return;
    }

    _voiceStep = '2/6 加载语音引擎...';
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      await mediasoup.init();
    } catch (e) {
      _voiceError = '步骤2 语音引擎初始化失败: $e';
      notifyListeners();
      return;
    }

    _voiceStep = '3/6 创建发送通道...';
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      await mediasoup.createSendTransport();
    } catch (e) {
      _voiceError = '步骤3 创建发送通道失败: $e';
      notifyListeners();
      return;
    }

    _voiceStep = '4/6 创建接收通道...';
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      await mediasoup.createRecvTransport();
    } catch (e) {
      _voiceError = '步骤4 创建接收通道失败: $e';
      notifyListeners();
      return;
    }

    _voiceStep = '5/6 获取麦克风并发送...';
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 200));

    try {
      await mediasoup.acquireMicStream();
      debugPrint('[VoiceProvider] acquireMicStream OK, calling produceMic...');
      mediasoup.produceMic();
      debugPrint('[VoiceProvider] produceMic called, waiting 3s...');
      await Future.delayed(const Duration(seconds: 3));
      debugPrint('[VoiceProvider] 3s wait done');
    } catch (e) {
      debugPrint('[VoiceProvider] mic produce failed: $e');
      _voiceError = '麦克风发送失败: $e';
      notifyListeners();
    }

    _voiceStep = '6/6 接收其他成员音频...';
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 200));

    for (final peer in _peers.values) {
      for (final prod in peer.producers.values) {
        try {
          await mediasoup.consume(peer.id, prod.id, prod.kind);
        } catch (e) {
          debugPrint('[VoiceProvider] consume failed: $e');
        }
      }
    }

    _voiceStep = _voiceError == null ? '语音已连接' : '';
    notifyListeners();
  }

  /// 离开频道
  Future<void> leaveChannel() async {
    if (_currentChannelId == null) return;

    await mediasoup.closeAll();
    socket.emit('leaveChannel', {}, (_) {});

    _currentChannelId = null;
    _currentChannelName = null;
    _peers.clear();
    _remoteVideoStreams.clear();
    _remoteAudioStreams.clear();
    notifyListeners();
  }

  /// 切换麦克风
  Future<void> toggleMic() async {
    await mediasoup.toggleMic();
    notifyListeners();
  }

  /// 切换摄像头
  Future<void> toggleCamera() async {
    if (!mediasoup.camEnabled) {
      final status = await Permission.camera.request();
      if (!status.isGranted) return;
    }
    try {
      await mediasoup.toggleCamera();
    } catch (e) {
      debugPrint('[VoiceProvider] toggleCamera failed: $e');
      _voiceError = '摄像头打开失败: $e';
    }
    notifyListeners();
  }

  /// 切换前后摄像头
  Future<void> switchCamera() async {
    await mediasoup.switchCamera();
  }

  bool isSelf(String peerId) => peerId == _selfId;

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    super.dispose();
  }
}
