import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' show DioException, Options, ResponseType;
import 'package:simple_live_core/simple_live_core.dart';
import '../common/http_client.dart' as core_http;
import '../common/web_socket_util.dart';
import 'native_live_danmaku.dart';
import '../scripts/douyin_sign.dart';
import 'proto/douyin.pb.dart';

class DouyinDanmakuArgs {
  final String webRid;
  final String roomId;
  final String userId;
  final String cookie;

  bool get hasSession => userId.isNotEmpty && cookie.isNotEmpty;
  DouyinDanmakuArgs({
    required this.webRid,
    required this.roomId,
    required this.userId,
    required this.cookie,
  });
  @override
  String toString() {
    return json.encode({"webRid": webRid, "roomId": roomId});
  }
}

class DouyinDanmaku extends NativeLiveDanmaku {
  DouyinDanmaku({this.refreshSession}) : super(4);

  final Future<DouyinDanmakuArgs> Function(String webRid, String roomId)?
  refreshSession;

  @override
  int heartbeatTime = 10 * 1000;

  String serverUrl = "wss://webcast3-ws-web-lq.douyin.com/webcast/im/push/v2/";
  RequestContext? _connectionRequest;
  RequestContext? _imRequest;

  @override
  Future<void> stop() {
    _connectionRequest?.cancel();
    _imRequest?.cancel();
    return super.stop();
  }

  @override
  Future<void> start(dynamic args) async {
    if (args is! DouyinDanmakuArgs) return;
    _connectionRequest?.cancel();
    _imRequest?.cancel();
    if (!await initializeNative() || !nativeActive) return;
    var dynamicHandshakePending = false;
    final connection = WebScoketUtils(
      url: serverUrl,
      // Playback and chat have independent lifetimes. In particular, a
      // quality switch must not cancel signing or a pending chat reconnect.
      prepareConnection: (retry) async {
        final request = RequestContext(timeout: const Duration(seconds: 8));
        _connectionRequest = request;
        try {
          return await request.run(() async {
            final refresh = refreshSession;
            final session = refresh != null && (retry || !args.hasSession)
                ? await refresh(args.webRid, args.roomId)
                : args;
            request.check();
            if (!session.hasSession) {
              throw CoreError('未获得抖音弹幕会话', kind: CoreErrorKind.authRequired);
            }
            final endpoint = Uri.parse(serverUrl);
            final signature = DouyinSign.getSignature(
              session.roomId,
              session.userId,
            );
            final query = _connectionQuery(session, signature);
            final headers = <String, dynamic>{
              'User-Agent': DouyinSite.kDefaultUserAgent,
              'Cookie': session.cookie,
              'Origin': 'https://live.douyin.com',
            };
            // A failed dynamic handshake gets a compatibility attempt before
            // another prefetch. An established socket can refresh its context.
            final im = dynamicHandshakePending
                ? null
                : await _fetchImContext(session, endpoint, query, headers);
            dynamicHandshakePending = im != null;
            if (im != null) {
              final heartbeat = im.response.heartbeatDuration;
              final interval = heartbeat.isNegative || heartbeat.isZero
                  ? null
                  : heartbeat.toInt().clamp(1000, 120000);
              return (
                url: im.endpoint
                    .replace(
                      queryParameters: {
                        ...query,
                        'resp_content_type': 'protobuf',
                        'cursor': im.cursor,
                        if (im.response.internalExt.isNotEmpty)
                          'internal_ext': im.response.internalExt,
                        'heartbeatDuration': (interval ?? 0).toString(),
                      },
                    )
                    .toString(),
                headers: {...headers, 'Referer': _roomReferer(session)},
                heartbeatTime: interval,
              );
            }
            final fallback = retry
                ? endpoint.replace(
                    host: endpoint.host.replaceFirst(
                      'webcast3-ws-web-lq',
                      'webcast5-ws-web-lf',
                    ),
                  )
                : endpoint;
            return (
              url: fallback.replace(queryParameters: query).toString(),
              headers: headers,
              heartbeatTime: null,
            );
          });
        } finally {
          if (identical(_connectionRequest, request)) _connectionRequest = null;
        }
      },
      heartBeatTime: heartbeatTime,
      onMessage: decodeMessage,
      onReady: () {
        dynamicHandshakePending = false;
        connectionReady();
        onReady?.call();
        heartbeat();
      },
      onHeartBeat: heartbeat,
      onReconnect: () => onClose?.call('与服务器断开连接，正在尝试重连'),
      onClose: (error) => onClose?.call(error),
    );
    webScoketUtils = connection;
    await connection.connect();
  }

  Map<String, String> _connectionQuery(
    DouyinDanmakuArgs session,
    String signature,
  ) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return {
      "app_name": "douyin_web",
      "version_code": "180800",
      "webcast_sdk_version": "1.3.0",
      "update_version_code": "1.3.0",
      "compress": "gzip",
      "cursor": "h-1_t-${timestamp}_r-1_d-1_u-1",
      "host": "https://live.douyin.com",
      "aid": "6383",
      "live_id": "1",
      "did_rule": "3",
      "debug": "false",
      "maxCacheMessageNumber": "20",
      "endpoint": "live_pc",
      "support_wrds": "1",
      "im_path": "/webcast/im/fetch/",
      "user_unique_id": session.userId,
      "device_platform": "web",
      "cookie_enabled": "true",
      "screen_width": "1920",
      "screen_height": "1080",
      "browser_language": "zh-CN",
      "browser_platform": "Win32",
      "browser_name": "Mozilla",
      "browser_version": DouyinSite.kDefaultUserAgent.replaceAll(
        "Mozilla/",
        "",
      ),
      "browser_online": "true",
      "tz_name": "Asia/Shanghai",
      "identity": "audience",
      "room_id": session.roomId,
      "heartbeatDuration": "0",
      "signature": signature,
    };
  }

  // Handshake adapted from June6699/dart_simple_live v1.12.8 (GPL-3.0).
  Future<({Uri endpoint, String cursor, Response response})?> _fetchImContext(
    DouyinDanmakuArgs session,
    Uri fallback,
    Map<String, String> query,
    Map<String, dynamic> headers,
  ) async {
    final context = RequestContext(timeout: const Duration(seconds: 2));
    _imRequest = context;
    try {
      return await context.run(() async {
        final uri = Uri.https('live.douyin.com', '/webcast/im/fetch/', {
          ...query,
          'resp_content_type': 'protobuf',
        });
        String? msToken;
        for (final part in session.cookie.split(';')) {
          final pair = part.trim();
          if (pair.startsWith('msToken=') && pair.length > 'msToken='.length) {
            msToken = pair.substring('msToken='.length);
            break;
          }
        }
        final url = DouyinSign.getAbogusUrl(
          uri.toString(),
          DouyinSite.kDefaultUserAgent,
          msToken: msToken,
        );
        final result = await core_http.HttpClient.instance.dio.get<List<int>>(
          url,
          cancelToken: context.cancelToken,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: false,
            headers: {
              ...headers,
              'Accept': 'application/json, text/plain, */*',
              'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
              'Referer': _roomReferer(session),
            },
          ),
        );
        final bytes = result.data;
        if (bytes == null || bytes.isEmpty) {
          CoreLog.d('[DouyinDanmaku] IM 预取响应为空，使用兼容连接');
          return null;
        }
        final response = Response.fromBuffer(
          bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
              ? gzip.decode(bytes)
              : bytes,
        );
        final cursor = response.cursor.trim().isNotEmpty
            ? response.cursor.trim()
            : response.liveCursor.trim();
        final endpoint = _pushEndpoint(response.pushServer.trim(), fallback);
        if (cursor.isEmpty || endpoint == null) {
          final reason = cursor.isEmpty ? '缺少游标' : '推送地址无效';
          CoreLog.d('[DouyinDanmaku] IM 预取$reason，使用兼容连接');
          return null;
        }
        CoreLog.d('[DouyinDanmaku] IM 预取成功，使用动态连接');
        return (endpoint: endpoint, cursor: cursor, response: response);
      });
    } catch (error) {
      if (error is CoreError && error.kind == CoreErrorKind.cancelled) rethrow;
      final status = error is DioException ? error.response?.statusCode : null;
      CoreLog.d(
        '[DouyinDanmaku] IM 预取失败${status == null ? '' : ' HTTP $status'}，使用兼容连接',
      );
      return null;
    } finally {
      if (identical(_imRequest, context)) _imRequest = null;
    }
  }

  String _roomReferer(DouyinDanmakuArgs session) =>
      'https://live.douyin.com/${session.webRid}';

  Uri? _pushEndpoint(String address, Uri fallback) {
    if (address.isEmpty) return fallback;
    var uri = Uri.tryParse(
      address.contains('://') ? address : 'wss://$address',
    );
    if (uri == null || uri.userInfo.isNotEmpty || uri.hasFragment) return null;
    if (uri.scheme == 'https') uri = uri.replace(scheme: 'wss');
    final sameEndpoint =
        uri.scheme == fallback.scheme &&
        uri.host == fallback.host &&
        uri.port == fallback.port;
    final douyinHost =
        uri.scheme == 'wss' &&
        (!uri.hasPort || uri.port == 443) &&
        RegExp(
          r'^webcast[0-9]*-ws-web-[a-z0-9-]+\.douyin\.com$',
        ).hasMatch(uri.host);
    if (!sameEndpoint && !douyinHost) return null;
    return uri.path.isEmpty || uri.path == '/'
        ? uri.replace(path: '/webcast/im/push/v2/')
        : uri;
  }

  @override
  void heartbeat() {
    var obj = PushFrame();
    obj.payloadType = 'hb';
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }
}
