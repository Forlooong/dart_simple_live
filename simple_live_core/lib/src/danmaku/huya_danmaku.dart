import 'dart:convert';
import '../common/web_socket_util.dart';
import 'native_live_danmaku.dart';

class HuyaDanmakuArgs {
  final int ayyuid;
  final int topSid;
  final int subSid;
  HuyaDanmakuArgs({
    required this.ayyuid,
    required this.topSid,
    required this.subSid,
  });
  @override
  String toString() {
    return json.encode({"ayyuid": ayyuid, "topSid": topSid, "subSid": subSid});
  }
}

class HuyaDanmaku extends NativeLiveDanmaku {
  HuyaDanmaku() : super(3);
  @override
  int heartbeatTime = 60 * 1000;

  String serverUrl = "wss://cdnws.api.huya.com";

  final heartbeatData = base64.decode("ABQdAAwsNgBM");

  late HuyaDanmakuArgs danmakuArgs;

  @override
  Future start(dynamic args) async {
    if (!await initializeNative() || !nativeActive) return;
    danmakuArgs = args as HuyaDanmakuArgs;
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        connectionReady();
        onReady?.call();
        joinRoom();
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        onClose?.call("服务器连接失败$e");
      },
    );
    webScoketUtils?.connect();
  }

  void joinRoom() {
    encodeAndSend({
      'kind': 'huya_join',
      'ayyuid': danmakuArgs.ayyuid,
      'top': danmakuArgs.topSid,
      'sub': danmakuArgs.subSid,
    });
  }

  @override
  void heartbeat() => sendWire(heartbeatData);
}
