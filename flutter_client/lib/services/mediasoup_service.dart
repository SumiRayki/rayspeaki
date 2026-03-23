import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
// flutter_webrtc is re-exported by mediasfu_mediasoup_client
import 'socket_service.dart';

/// MediaSoup WebRTC 服务 — 管理音视频传输
class MediasoupService {
  final SocketService _socket;

  Device? _device;
  Transport? _sendTransport;
  Transport? _recvTransport;
  Producer? _micProducer;
  Producer? _camProducer;
  final Map<String, Consumer> _consumers = {};

  bool _micEnabled = false;
  bool _camEnabled = false;
  MediaStream? _micStream;
  MediaStream? _camStream;

  bool get micEnabled => _micEnabled;
  bool get camEnabled => _camEnabled;
  MediaStream? get testMicStream => _micStream;
  MediaStream? get localCamStream => _camStream;
  Map<String, Consumer> get consumers => Map.unmodifiable(_consumers);

  // 新 consumer 回调 — 上层监听以获取音视频流
  final _consumerController =
      StreamController<ConsumerEvent>.broadcast();
  Stream<ConsumerEvent> get onConsumer => _consumerController.stream;

  MediasoupService(this._socket);

  /// 初始化 Device，加载 RTP capabilities
  Future<void> init() async {
    final rawResp = await _socket.emitAsync('getRtpCapabilities', {});
    final resp = rawResp is Map<String, dynamic> ? rawResp : <String, dynamic>{};
    final caps = resp['routerRtpCapabilities'];
    if (caps == null || caps is! Map<String, dynamic>) {
      throw Exception('未获取到 RTP capabilities');
    }
    final rtpCaps = RtpCapabilities.fromMap(caps);
    _device = Device();
    await _device!.load(routerRtpCapabilities: rtpCaps);
    debugPrint('[mediasoup] device loaded, codecs: ${_device!.rtpCapabilities.codecs.map((c) => c.mimeType).toList()}');
  }

  /// 从服务器响应解析 transport 参数并手动创建（避免 FromMap 的隐含 constraints）
  Transport _createTransportFromResp(
    Map<String, dynamic> resp,
    Direction direction, {
    Function? producerCallback,
    Function? consumerCallback,
  }) {
    final id = resp['id'] as String;
    final iceParams = IceParameters.fromMap(
        resp['iceParameters'] as Map<String, dynamic>);
    final iceCandidates = (resp['iceCandidates'] as List)
        .map((c) => IceCandidate.fromMap(c as Map<String, dynamic>))
        .toList();
    final dtlsParams = DtlsParameters.fromMap(
        resp['dtlsParameters'] as Map<String, dynamic>);
    final sctpParams = resp['sctpParameters'] != null
        ? SctpParameters.fromMap(resp['sctpParameters'] as Map<String, dynamic>)
        : null;

    if (direction == Direction.send) {
      return _device!.createSendTransport(
        id: id,
        iceParameters: iceParams,
        iceCandidates: iceCandidates,
        dtlsParameters: dtlsParams,
        sctpParameters: sctpParams,
        producerCallback: producerCallback,
      );
    } else {
      return _device!.createRecvTransport(
        id: id,
        iceParameters: iceParams,
        iceCandidates: iceCandidates,
        dtlsParameters: dtlsParams,
        sctpParameters: sctpParams,
        consumerCallback: consumerCallback,
      );
    }
  }

  /// 创建发送 Transport
  Future<void> createSendTransport() async {
    final rawResp =
        await _socket.emitAsync('createTransport', {'direction': 'send'});
    final resp = rawResp is Map<String, dynamic> ? rawResp : <String, dynamic>{};

    _sendTransport = _createTransportFromResp(
      resp,
      Direction.send,
      producerCallback: (Producer producer) {
        if (producer.source == 'mic') {
          _micProducer = producer;
        } else if (producer.source == 'screen') {
          _camProducer = producer;
        }
      },
    );

    // 监听 connect 事件 — 发送 DTLS 参数到服务器
    _sendTransport!.on('connect', (Map data) {
      try {
        final dtls = data['dtlsParameters'];
        final dtlsMap = dtls is DtlsParameters ? dtls.toMap() : dtls as Map;
        _socket.emit('connectTransport', {
          'transportId': _sendTransport!.id,
          'dtlsParameters': dtlsMap,
        }, (_) {});
        final callback = data['callback'] as Function;
        callback();
      } catch (e) {
        debugPrint('[mediasoup] send connect error: $e');
        final errback = data['errback'];
        if (errback is Function) errback(e);
      }
    });

    // 监听 produce 事件 — 通知服务器有新的 producer
    _sendTransport!.on('produce', (Map data) async {
      final callback = data['callback'] as Function;
      final errback = data['errback'] as Function;

      try {
        final rtpParams = data['rtpParameters'];
        final rtpMap = rtpParams is RtpParameters ? rtpParams.toMap() : rtpParams as Map;
        final rawResp = await _socket.emitAsync('produce', {
          'transportId': _sendTransport!.id,
          'kind': data['kind'],
          'rtpParameters': rtpMap,
          'appData': data['appData'] ?? {},
        });

        final resp = rawResp is Map<String, dynamic> ? rawResp : <String, dynamic>{};
        final producerId = resp['producerId'];
        if (producerId is String) {
          callback(producerId);
        } else {
          errback(Exception('producerId not found'));
        }
      } catch (e) {
        debugPrint('[mediasoup] produce event error: $e');
        errback(e);
      }
    });
  }

  /// 创建接收 Transport
  Future<void> createRecvTransport() async {
    final rawResp =
        await _socket.emitAsync('createTransport', {'direction': 'recv'});
    final resp = rawResp is Map<String, dynamic> ? rawResp : <String, dynamic>{};

    _recvTransport = _createTransportFromResp(
      resp,
      Direction.recv,
      consumerCallback: (Consumer consumer, dynamic accept) {
        debugPrint('[mediasoup] consumerCallback: id=${consumer.id} kind=${consumer.kind} peerId=${consumer.peerId} stream=${consumer.stream?.id} tracks=${consumer.stream?.getTracks().length}');
        _consumers[consumer.id] = consumer;
        if (accept is Function) accept();
        _consumerController.add(ConsumerEvent(
          consumer: consumer,
          peerId: consumer.peerId ?? '',
        ));
      },
    );

    // 监听 connect 事件
    _recvTransport!.on('connect', (Map data) {
      try {
        final dtls = data['dtlsParameters'];
        final dtlsMap = dtls is DtlsParameters ? dtls.toMap() : dtls as Map;
        _socket.emit('connectTransport', {
          'transportId': _recvTransport!.id,
          'dtlsParameters': dtlsMap,
        }, (_) {});
        final callback = data['callback'] as Function;
        callback();
      } catch (e) {
        debugPrint('[mediasoup] recv connect error: $e');
        final errback = data['errback'];
        if (errback is Function) errback(e);
      }
    });
  }

  /// 步骤1: 仅获取麦克风流
  Future<void> acquireMicStream() async {
    _micStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
    });
  }

  /// 步骤2: 将麦克风流发送到服务器
  void produceMic() {
    if (_sendTransport == null || _micStream == null) return;
    if (_micProducer != null) return;

    final track = _micStream!.getAudioTracks().first;

    _sendTransport!.produce(
      track: track,
      stream: _micStream!,
      codecOptions: ProducerCodecOptions(),
      source: 'mic',
      appData: {'source': 'mic'},
    );

    _micEnabled = true;
  }

  /// 开启麦克风（合并两步）
  Future<void> enableMic() async {
    await acquireMicStream();
    produceMic();
  }

  /// 关闭麦克风
  Future<void> disableMic() async {
    if (_micProducer == null) return;

    try { _micProducer!.close(); } catch (_) {}
    try {
      _socket.emit('closeProducer', {'producerId': _micProducer!.id}, (_) {});
    } catch (_) {}
    _micProducer = null;
    _micEnabled = false;
    if (_micStream != null) {
      try {
        for (final track in _micStream!.getTracks()) {
          track.stop();
        }
      } catch (_) {}
      _micStream = null;
    }
  }

  /// 切换麦克风
  Future<void> toggleMic() async {
    if (_micEnabled) {
      await disableMic();
    } else {
      await enableMic();
    }
  }

  /// 开启摄像头（走 screen 通道，兼容 Electron/Web 客户端的屏幕分享）
  Future<void> enableCamera({bool useFront = true}) async {
    if (_sendTransport == null) return;
    if (_camProducer != null) return;

    // 加超时保护，模拟器可能没有摄像头导致 getUserMedia 卡死
    final stream = await navigator.mediaDevices.getUserMedia({
      'video': {
        'facingMode': useFront ? 'user' : 'environment',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      }
    }).timeout(const Duration(seconds: 8), onTimeout: () {
      throw Exception('获取摄像头超时，设备可能不支持');
    });

    _camStream = stream;
    final track = stream.getVideoTracks().first;

    _sendTransport!.produce(
      track: track,
      stream: stream,
      codecOptions: ProducerCodecOptions(
        videoGoogleStartBitrate: 1000,
      ),
      source: 'screen',
      appData: {'source': 'screen'},
    );

    _camEnabled = true;
  }

  /// 关闭摄像头
  Future<void> disableCamera() async {
    if (_camProducer == null) return;

    try { _camProducer!.close(); } catch (_) {}
    try {
      _socket.emit('closeProducer', {'producerId': _camProducer!.id}, (_) {});
    } catch (_) {}
    _camProducer = null;
    _camEnabled = false;
    if (_camStream != null) {
      try {
        for (final track in _camStream!.getTracks()) {
          track.stop();
        }
      } catch (_) {}
      _camStream = null;
    }
  }

  /// 切换摄像头
  Future<void> toggleCamera() async {
    if (_camEnabled) {
      await disableCamera();
    } else {
      await enableCamera();
    }
  }

  /// 切换前后摄像头
  Future<void> switchCamera() async {
    if (_camProducer == null) return;
    final track = _camProducer!.track;
    await Helper.switchCamera(track);
  }

  /// 消费远端 producer
  Future<void> consume(String peerId, String producerId, String kind) async {
    if (_device == null || _recvTransport == null) {
      debugPrint('[mediasoup] consume skipped: device=$_device recvTransport=$_recvTransport');
      return;
    }

    debugPrint('[mediasoup] consume: peerId=$peerId producerId=$producerId kind=$kind');
    final caps = _device!.rtpCapabilities.toMap();
    final codecs = (caps['codecs'] as List?)?.map((c) => '${c['mimeType']}').toList();
    debugPrint('[mediasoup] rtpCapabilities codecs: $codecs');
    final rawResp = await _socket.emitAsync('consume', {
      'producerId': producerId,
      'rtpCapabilities': caps,
    });
    debugPrint('[mediasoup] consume resp: $rawResp');

    final resp = rawResp is Map<String, dynamic> ? rawResp : <String, dynamic>{};

    _recvTransport!.consume(
      id: resp['id'] as String,
      producerId: resp['producerId'] as String,
      peerId: peerId,
      kind: RTCRtpMediaTypeExtension.fromString(resp['kind'] as String),
      rtpParameters:
          RtpParameters.fromMap(resp['rtpParameters'] as Map<String, dynamic>),
    );
  }

  /// 关闭指定 consumer
  void closeConsumer(String consumerId) {
    try { _consumers[consumerId]?.close(); } catch (_) {}
    _consumers.remove(consumerId);
  }

  /// 关闭所有 — 离开频道时调用
  Future<void> closeAll() async {
    try { await disableMic(); } catch (_) {}
    try { await disableCamera(); } catch (_) {}

    for (final c in _consumers.values) {
      try { c.close(); } catch (_) {}
    }
    _consumers.clear();

    if (_sendTransport != null) {
      try { await _sendTransport!.close(); } catch (_) {}
      _sendTransport = null;
    }
    if (_recvTransport != null) {
      try { await _recvTransport!.close(); } catch (_) {}
      _recvTransport = null;
    }
  }

  void dispose() {
    closeAll();
    _consumerController.close();
    _device = null;
  }
}

/// Consumer 事件 — 包含 consumer 和对应的 peerId
class ConsumerEvent {
  final Consumer consumer;
  final String peerId;

  ConsumerEvent({required this.consumer, required this.peerId});
}
