import 'dart:convert';
import 'package:simple_live_core/simple_live_core.dart';
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

  @override
  Future<void> start(dynamic args) async {
    if (args is! DouyinDanmakuArgs) return;
    if (!await initializeNative() || !nativeActive) return;
    final connection = WebScoketUtils(
      url: serverUrl,
      // Playback and chat have independent lifetimes. In particular, a
      // quality switch must not cancel signing or a pending chat reconnect.
      prepareConnection: (retry) =>
          RequestContext(timeout: const Duration(seconds: 6)).run(() async {
            final refresh = refreshSession;
            final session = refresh != null && (retry || !args.hasSession)
                ? await refresh(args.webRid, args.roomId)
                : args;
            if (!session.hasSession) {
              throw CoreError('未获得抖音弹幕会话', kind: CoreErrorKind.authRequired);
            }
            return _connectionOptions(session, retry);
          }),
      heartBeatTime: heartbeatTime,
      onMessage: decodeMessage,
      onReady: () {
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

  ({String url, Map<String, dynamic> headers}) _connectionOptions(
    DouyinDanmakuArgs session,
    bool retry,
  ) {
    final signature = DouyinSign.getSignature(session.roomId, session.userId);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final endpoint = Uri.parse(serverUrl);
    final uri = endpoint.replace(
      host: retry
          ? endpoint.host.replaceFirst(
              "webcast3-ws-web-lq",
              "webcast5-ws-web-lf",
            )
          : endpoint.host,
      queryParameters: {
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
      },
    );
    return (
      url: uri.toString(),
      headers: {
        "User-Agent": DouyinSite.kDefaultUserAgent,
        "Cookie": session.cookie,
        "Origin": "https://live.douyin.com",
      },
    );
  }

  @override
  void heartbeat() {
    var obj = PushFrame();
    obj.payloadType = 'hb';
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }
}
