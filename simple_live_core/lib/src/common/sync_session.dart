import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// A short lived, out-of-band paired channel. The key is only shown locally
/// (QR/link fragment), never advertised through discovery or sent over HTTP.
class SyncCipher {
  static final _algorithm = AesGcm.with256bits();
  static const maxBytes = 2 * 1024 * 1024;
  final SecretKey _key;
  final Set<String> _received = {};
  SyncCipher(String key) : _key = SecretKey(_decodeKey(key));

  static List<int> _decodeKey(String key) {
    final bytes = base64Url.decode(base64Url.normalize(key));
    if (bytes.length != 32) throw const FormatException('配对码无效');
    return bytes;
  }

  static Future<String> newKey() async =>
      base64Url.encode(await (await _algorithm.newSecretKey()).extractBytes());

  Future<Map<String, dynamic>> seal(Object? data, String purpose) async {
    final bytes = utf8.encode(jsonEncode(data));
    if (bytes.length > maxBytes) throw const FormatException('同步数据过大');
    final box = await _algorithm.encrypt(
      bytes,
      secretKey: _key,
      aad: utf8.encode('simple-live-sync-v2:$purpose'),
    );
    return {
      'v': 2,
      'nonce': base64Url.encode(box.nonce),
      'data': base64Url.encode(box.cipherText),
      'mac': base64Url.encode(box.mac.bytes),
    };
  }

  Future<dynamic> open(Map<String, dynamic> envelope, String purpose) async {
    if (envelope['v'] != 2 || _received.length >= 10000) {
      throw const FormatException('同步会话无效');
    }
    final nonceBytes = base64Url.decode(envelope['nonce'] as String);
    if (nonceBytes.length != 12) throw const FormatException('同步数据无效');
    final replayKey = '$purpose:${base64Url.encode(nonceBytes)}';
    if (!_received.add(replayKey)) throw const FormatException('重复请求');
    try {
      final cipherText = base64Url.decode(envelope['data'] as String);
      final mac = base64Url.decode(envelope['mac'] as String);
      if (cipherText.length > maxBytes ||
          nonceBytes.length != 12 ||
          mac.length != 16) {
        throw const FormatException('同步数据无效');
      }
      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonceBytes, mac: Mac(mac)),
        secretKey: _key,
        aad: utf8.encode('simple-live-sync-v2:$purpose'),
      );
      return jsonDecode(utf8.decode(clear));
    } catch (_) {
      _received.remove(replayKey);
      rethrow;
    }
  }
}

/// Shared by App and TV: bounded requests, explicit approval, one peer,
/// replay rejection, expiry and start/stop races all have the same contract.
class SecureSyncServer {
  final Future<bool> Function(String peer) approve;
  final Future<Object?> Function(Map<String, dynamic> request) handle;
  final void Function()? onStopped;
  final Duration lifetime;
  HttpServer? _server;
  Timer? _expiry;
  SyncCipher? _cipher;
  String? _peer;
  int? _busyGeneration;
  int _generation = 0;
  Future<void> _lifecycle = Future.value();
  String pairingKey = '';
  bool get running => _cipher != null && _server != null;
  int? get port => _server?.port;

  SecureSyncServer({
    required this.approve,
    required this.handle,
    this.onStopped,
    this.lifetime = const Duration(minutes: 10),
  });

  Future<void> start({InternetAddress? address, int port = 23234}) {
    final generation = _generation;
    final operation = _lifecycle.then((_) async {
      if (generation != _generation || running) return;
      final key = await SyncCipher.newKey();
      final server = await HttpServer.bind(
        address ?? InternetAddress.anyIPv4,
        port,
      );
      if (generation != _generation) {
        await server.close(force: true);
        return;
      }
      pairingKey = key;
      _cipher = SyncCipher(key);
      _server = server;
      _peer = null;
      _expiry = Timer(lifetime, () {
        unawaited(stop());
      });
      server.listen((request) {
        // A peer can disconnect while a response is written or while stop()
        // force-closes sockets. Never leak those IO failures to the UI isolate.
        unawaited(_receive(request, generation).catchError((Object _) {}));
      });
    });
    _lifecycle = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> stop() {
    ++_generation;
    _cipher = null;
    pairingKey = '';
    _peer = null;
    _expiry?.cancel();
    onStopped?.call();
    final operation = _lifecycle.then((_) async {
      final server = _server;
      _server = null;
      await server?.close(force: true);
    });
    _lifecycle = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _receive(HttpRequest request, int generation) async {
    // One write at a time also prevents duplicate approval dialogs and bounds
    // memory used by clients that send slow or concurrent request bodies.
    if (_busyGeneration == generation ||
        generation != _generation ||
        _cipher == null ||
        request.method != 'POST' ||
        request.uri.path != '/secure' ||
        request.contentLength > SyncCipher.maxBytes * 2) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    _busyGeneration = generation;
    final cipher = _cipher!;
    try {
      final bytes = <int>[];
      final clock = Stopwatch()..start();
      final chunks = StreamIterator(request);
      try {
        while (await chunks.moveNext().timeout(
          const Duration(seconds: 10) - clock.elapsed,
        )) {
          if (bytes.length + chunks.current.length > SyncCipher.maxBytes * 2) {
            throw const FormatException('同步数据过大');
          }
          bytes.addAll(chunks.current);
        }
      } finally {
        await chunks.cancel();
      }
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final payload =
          await cipher.open(envelope, 'request') as Map<String, dynamic>;
      final peer = request.connectionInfo!.remoteAddress.address;
      if (generation != _generation || (_peer != null && _peer != peer)) {
        throw const FormatException('会话已关闭');
      }
      if (_peer == null) {
        if (!await approve(peer).timeout(const Duration(seconds: 45))) {
          throw const FormatException('接收端拒绝配对');
        }
        if (generation != _generation) throw const FormatException('会话已关闭');
        _peer = peer;
      }
      final result = await handle(payload);
      if (generation != _generation) throw const FormatException('会话已关闭');
      final response = await cipher.seal(
        result,
        'response:${envelope['nonce']}',
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
    } catch (_) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('Sync request rejected');
    } finally {
      if (_busyGeneration == generation) _busyGeneration = null;
      await request.response.close();
    }
  }
}
