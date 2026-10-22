import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/services/sync_service.dart';

class SyncClientRequest {
  // Only encrypted envelopes leave this transport; no body/error interceptor.
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  Future<dynamic> _send(
    SyncClinet client,
    String path,
    dynamic body, {
    bool overlay = false,
  }) async {
    final cipher = client.cipher;
    if (cipher == null) throw const FormatException('请先扫描或输入接收端配对码');
    if (body is String) body = jsonDecode(body);
    final envelope = await cipher.seal({
      'path': path,
      'body': body,
      'overlay': overlay,
    }, 'request');
    try {
      final response = await _dio.post(
        'http://${client.address}:${client.port}/secure',
        data: envelope,
      );
      return await cipher.open(
        Map<String, dynamic>.from(response.data as Map),
        'response:${envelope['nonce']}',
      );
    } catch (_) {
      throw const FormatException('同步连接失败，请确认接收端批准配对且会话未过期');
    }
  }

  Future<SyncClientInfoModel> getClientInfo(SyncClinet client) async =>
      SyncClientInfoModel.fromJson(await _send(client, '/info', null));

  Future<bool> _sync(
    SyncClinet client,
    String path,
    dynamic body,
    bool overlay,
  ) async {
    final data = await _send(client, path, body, overlay: overlay);
    if (data['status'] != true) {
      throw const FormatException('接收端未完成同步，请检查数据后重试');
    }
    return true;
  }

  Future<bool> syncFollow(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) => _sync(client, '/sync/follow', body, overlay);
  Future<bool> syncTag(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) => _sync(client, '/sync/tag', body, overlay);
  Future<bool> syncHistory(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) => _sync(client, '/sync/history', body, overlay);
  Future<bool> syncBlockedWord(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) => _sync(client, '/sync/blocked_word', body, overlay);
  Future<bool> syncBiliAccount(SyncClinet client, String cookie) =>
      _sync(client, '/sync/account/bilibili', {'cookie': cookie}, false);
}
