import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config.dart';

typedef EventCallback = void Function(dynamic data);

/// Socket.IO 信令服务 — 管理与服务端的实时通信
class SocketService {
  io.Socket? _socket;
  final _eventControllers = <String, StreamController<dynamic>>{};

  bool get isConnected => _socket?.connected ?? false;

  /// 连接 Socket.IO 并认证
  void connect(String token) {
    disconnect();

    _socket = io.io(
      AppConfig.socketUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setExtraHeaders({'X-Session-Token': token})
          .setQuery({'token': token})
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionAttempts(100)
          .build(),
    );

    _socket!.onConnect((_) {
      // 连接后立即认证
      emit('authenticate', {'token': token}, (resp) {
        _fire('authenticated', resp);
      });
    });

    _socket!.onDisconnect((_) => _fire('disconnected', null));
    _socket!.onReconnect((_) => _fire('reconnected', null));
    _socket!.onError((err) => _fire('error', err));

    // 监听服务端推送事件
    for (final event in [
      'initialState',
      'joinedChannel',
      'peerJoined',
      'peerLeft',
      'newProducer',
      'producerClosed',
      'channelMembersUpdated',
      'onlineUsersUpdated',
      'ipChanged',
      'error',
    ]) {
      _socket!.on(event, (data) => _fire(event, data));
    }

    _socket!.connect();
  }

  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }

  /// 发送事件并等待 ack 回调
  Future<dynamic> emitAsync(String event, Map<String, dynamic> data) {
    final completer = Completer<dynamic>();
    _socket?.emitWithAck(event, data, ack: (resp) {
      completer.complete(resp);
    });
    // 超时 10s
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('$event 超时'),
    );
  }

  /// 发送事件（带 ack callback）
  void emit(String event, Map<String, dynamic> data,
      [Function(dynamic)? ack]) {
    if (ack != null) {
      _socket?.emitWithAck(event, data, ack: ack);
    } else {
      _socket?.emit(event, data);
    }
  }

  /// 订阅事件流
  Stream<dynamic> on(String event) {
    _eventControllers[event] ??= StreamController<dynamic>.broadcast();
    return _eventControllers[event]!.stream;
  }

  void _fire(String event, dynamic data) {
    _eventControllers[event]?.add(data);
  }

  void dispose() {
    disconnect();
    for (final c in _eventControllers.values) {
      c.close();
    }
    _eventControllers.clear();
  }
}
