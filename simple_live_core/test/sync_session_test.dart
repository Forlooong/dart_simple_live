import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/src/common/sync_session.dart';
import 'package:test/test.dart';

void main() {
  Future<(int, String)> post(
    int port,
    Object body, {
    String path = '/secure',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.post('127.0.0.1', port, path);
      request.write(jsonEncode(body));
      final response = await request.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    } finally {
      client.close(force: true);
    }
  }

  test('encrypted request, response binding, wrong key and replay', () async {
    final key = await SyncCipher.newKey();
    final sender = SyncCipher(key);
    final receiver = SyncCipher(key);
    var request = await sender.seal({'cookie': 'CANARY-secret'}, 'request');
    while (!(request['nonce'] as String).contains(RegExp('[-_]'))) {
      request = await sender.seal({'cookie': 'CANARY-secret'}, 'request');
    }
    expect(jsonEncode(request), isNot(contains('CANARY-secret')));
    expect(await receiver.open(request, 'request'), {
      'cookie': 'CANARY-secret',
    });
    await expectLater(receiver.open(request, 'request'), throwsFormatException);
    await expectLater(
      receiver.open({
        ...request,
        'nonce': base64.encode(base64Url.decode(request['nonce'] as String)),
      }, 'request'),
      throwsFormatException,
    );
    await expectLater(
      SyncCipher(await SyncCipher.newKey()).open(request, 'request'),
      throwsA(anything),
    );
    final response = await receiver.seal({
      'status': true,
    }, 'response:${request['nonce']}');
    await expectLater(
      sender.open(response, 'response:other'),
      throwsA(anything),
    );
    expect(await sender.open(response, 'response:${request['nonce']}'), {
      'status': true,
    });
  });

  test(
    'only authenticated and approved requests can write; stop releases port',
    () async {
      var writes = 0;
      var approvals = 0;
      final server = SecureSyncServer(
        approve: (_) async {
          approvals++;
          return true;
        },
        handle: (_) async {
          writes++;
          return {'status': true};
        },
      );
      addTearDown(server.stop);
      expect(server.running, isFalse);
      await server.start(address: InternetAddress.loopbackIPv4, port: 0);
      final port = server.port!;
      expect((await post(port, {}, path: '/sync/follow')).$1, 403);
      expect((await post(port, {'cookie': 'plaintext'})).$1, 403);
      expect(writes, 0);
      expect(approvals, 0);
      final cipher = SyncCipher(server.pairingKey);
      final request = await cipher.seal({'path': '/sync/follow'}, 'request');
      final response = await post(port, request);
      expect(response.$1, 200);
      expect(
        await cipher.open(
          jsonDecode(response.$2),
          'response:${request['nonce']}',
        ),
        {'status': true},
      );
      expect((await post(port, request)).$1, 403);
      expect(writes, 1);
      expect(approvals, 1);
      await server.stop();
      expect(server.running, isFalse);
      expect(server.pairingKey, isEmpty);
      final rebound = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close(force: true);
    },
  );

  test('rejected approval and closing during approval never commit', () async {
    var writes = 0;
    final approval = Completer<bool>();
    final requested = Completer<void>();
    final server = SecureSyncServer(
      approve: (_) {
        requested.complete();
        return approval.future;
      },
      handle: (_) async {
        writes++;
        return {};
      },
    );
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final envelope = await SyncCipher(server.pairingKey).seal({}, 'request');
    final response = post(
      server.port!,
      envelope,
    ).catchError((_) => (0, 'closed'));
    await requested.future;
    await server.stop();
    approval.complete(true);
    await response;
    expect(writes, 0);
  });

  test(
    'stop while starting, repeated stop, expiry and fresh session',
    () async {
      final server = SecureSyncServer(
        approve: (_) async => false,
        handle: (_) async => {},
        lifetime: const Duration(milliseconds: 30),
      );
      final starting = server.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      await server.stop();
      await starting;
      expect(server.running, isFalse);
      await server.stop();
      await server.start(address: InternetAddress.loopbackIPv4, port: 0);
      final key = server.pairingKey;
      final request = await SyncCipher(key).seal({}, 'request');
      expect((await post(server.port!, request)).$1, 403);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(server.running, isFalse);
      await server.stop();
      await server.start(address: InternetAddress.loopbackIPv4, port: 0);
      expect(server.pairingKey, isNot(key));
      await server.stop();
    },
  );
}
