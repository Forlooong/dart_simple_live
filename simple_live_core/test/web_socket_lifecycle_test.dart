import 'dart:async';
import 'dart:io';

import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:test/test.dart';

const deadline = Duration(seconds: 3);

void main() {
  test('closing during handshake prevents late ready and heartbeat', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = StreamIterator(server);
    addTearDown(() async {
      await requests.cancel();
      await server.close(force: true);
    });
    var readyCount = 0;
    var heartbeatCount = 0;
    var reconnectCount = 0;
    final client = WebScoketUtils(
      url: 'ws://127.0.0.1:${server.port}',
      heartBeatTime: 10,
      onReady: () => readyCount++,
      onHeartBeat: () => heartbeatCount++,
      onReconnect: () => reconnectCount++,
    );
    addTearDown(client.close);

    final connecting = client.connect();
    expect(await requests.moveNext().timeout(deadline), isTrue);
    // Hold the upgrade until close has invalidated this connection generation.
    client.close();
    final peer = await WebSocketTransformer.upgrade(requests.current);
    final peerClosed = Completer<void>();
    final subscription = peer.listen((_) {}, onDone: peerClosed.complete);
    addTearDown(subscription.cancel);
    await connecting.timeout(deadline);
    await peerClosed.future.timeout(deadline);

    expect(readyCount, 0);
    expect(heartbeatCount, 0);
    expect(reconnectCount, 0);
    expect(client.status, SocketStatus.closed);
    expect(client.heartBeatTimer, isNull);
    expect(client.reconnectTimer, isNull);
  });

  test(
    'closing a connected socket stops heartbeat without reconnect',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = StreamIterator(server);
      addTearDown(() async {
        await requests.cancel();
        await server.close(force: true);
      });
      var readyCount = 0;
      var heartbeatCount = 0;
      var reconnectCount = 0;
      final firstHeartbeat = Completer<void>();
      late final WebScoketUtils client;
      client = WebScoketUtils(
        url: 'ws://127.0.0.1:${server.port}',
        heartBeatTime: 10,
        onReady: () => readyCount++,
        onHeartBeat: () {
          heartbeatCount++;
          client.sendMessage('heartbeat');
        },
        onReconnect: () => reconnectCount++,
      );
      addTearDown(client.close);

      final connecting = client.connect();
      expect(await requests.moveNext().timeout(deadline), isTrue);
      final peer = await WebSocketTransformer.upgrade(requests.current);
      final peerClosed = Completer<void>();
      final messages = <dynamic>[];
      final subscription = peer.listen((message) {
        messages.add(message);
        if (!firstHeartbeat.isCompleted) firstHeartbeat.complete();
      }, onDone: peerClosed.complete);
      addTearDown(subscription.cancel);
      await connecting.timeout(deadline);
      await firstHeartbeat.future.timeout(deadline);
      expect(readyCount, 1);
      expect(client.status, SocketStatus.connected);

      client.close();
      final heartbeatCountAtClose = heartbeatCount;
      client.sendMessage('must not be delivered');
      await peerClosed.future.timeout(deadline);
      // Cover several heartbeat intervals, without waiting for reconnect delay.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(heartbeatCount, heartbeatCountAtClose);
      expect(messages, isNotEmpty);
      expect(messages.every((message) => message == 'heartbeat'), isTrue);
      expect(reconnectCount, 0);
      expect(client.status, SocketStatus.closed);
      expect(client.heartBeatTimer, isNull);
      expect(client.reconnectTimer, isNull);
    },
  );
}
