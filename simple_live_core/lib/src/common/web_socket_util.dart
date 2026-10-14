import 'dart:async';
import 'dart:math';
import 'package:web_socket_channel/io.dart';

enum SocketStatus { connected, failed, closed }

class WebScoketUtils {
  WebScoketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.backupUrl,
  });
  final String url;
  final String? backupUrl;
  final int heartBeatTime;
  final void Function(dynamic)? onMessage;
  final void Function(String)? onClose;
  final void Function()? onReconnect, onReady, onHeartBeat;
  Map<String, dynamic>? headers;
  SocketStatus status = SocketStatus.closed;
  IOWebSocketChannel? webSocket;
  StreamSubscription<dynamic>? streamSubscription;
  Timer? heartBeatTimer, reconnectTimer;
  int reconnectTime = 0, maxReconnectTime = 5;
  int _generation = 0;
  bool _explicitlyClosed = true;

  Future<void> connect({bool retry = false}) async {
    _disconnect();
    _explicitlyClosed = false;
    final generation = ++_generation;
    try {
      final socket = IOWebSocketChannel.connect(
        retry && backupUrl != null && backupUrl!.isNotEmpty ? backupUrl! : url,
        connectTimeout: const Duration(seconds: 10),
        headers: headers,
      );
      webSocket = socket;
      await socket.ready;
      if (_explicitlyClosed || generation != _generation) {
        await socket.sink.close();
        return;
      }
      status = SocketStatus.connected;
      streamSubscription = socket.stream.listen(
        (data) {
          if (!_explicitlyClosed && generation == _generation)
            onMessage?.call(data);
        },
        onError: (Object error, StackTrace stack) {
          if (generation == _generation) _scheduleReconnect();
        },
        onDone: () {
          if (generation == _generation) _scheduleReconnect();
        },
      );
      onReady?.call();
      if (!_explicitlyClosed &&
          generation == _generation &&
          heartBeatTime > 0) {
        heartBeatTimer = Timer.periodic(Duration(milliseconds: heartBeatTime), (
          _,
        ) {
          if (generation == _generation) onHeartBeat?.call();
        });
      }
    } catch (error) {
      if (!_explicitlyClosed && generation == _generation) _scheduleReconnect();
    }
  }

  void markValidPayload() => reconnectTime = 0;
  void restartAfterProtocolError() => _scheduleReconnect();
  void reconnect() => _scheduleReconnect();
  void _scheduleReconnect() {
    if (_explicitlyClosed || reconnectTimer != null) return;
    ++_generation;
    _disconnect();
    status = SocketStatus.failed;
    if (reconnectTime >= maxReconnectTime) {
      close();
      onClose?.call('重连超过最大次数，与弹幕服务器断开连接');
      return;
    }
    reconnectTime++;
    onReconnect?.call();
    reconnectTimer = Timer(Duration(seconds: min(5 * reconnectTime, 30)), () {
      reconnectTimer = null;
      if (!_explicitlyClosed) unawaited(connect(retry: true));
    });
  }

  void sendMessage(dynamic message) {
    if (status == SocketStatus.connected && !_explicitlyClosed)
      webSocket?.sink.add(message);
  }

  void _disconnect() {
    _ignoreTeardown(streamSubscription?.cancel());
    streamSubscription = null;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    heartBeatTimer?.cancel();
    heartBeatTimer = null;
    _ignoreTeardown(webSocket?.sink.close());
    webSocket = null;
    status = SocketStatus.closed;
  }

  void close() {
    _explicitlyClosed = true;
    ++_generation;
    _disconnect();
  }

  void _ignoreTeardown(Future<dynamic>? task) {
    if (task != null)
      unawaited(task.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }
}
