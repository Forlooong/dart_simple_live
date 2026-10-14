import 'dart:convert';
import 'package:danmaku_native/danmaku_native.dart';
import '../common/web_socket_util.dart';
import 'native_live_danmaku.dart';

class BiliBiliDanmakuArgs {
  final int roomId;
  final String token;
  final String buvid;
  final String serverHost;
  final int uid;
  final String cookie;
  BiliBiliDanmakuArgs({
    required this.roomId,
    required this.token,
    required this.serverHost,
    required this.buvid,
    required this.uid,
    required this.cookie,
  });
  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "token": token,
      "serverHost": serverHost,
      "buvid": buvid,
      "uid": uid,
      "cookie": cookie,
    });
  }
}

class BiliBiliDanmaku extends NativeLiveDanmaku {
  BiliBiliDanmaku() : super(1);
  @override
  int heartbeatTime = 60 * 1000;

  //String serverUrl = "wss://broadcastlv.chat.bilibili.com/sub";

  late BiliBiliDanmakuArgs danmakuArgs;
  @override
  Future start(dynamic args) async {
    if (!await initializeNative() || !nativeActive) return;
    danmakuArgs = args as BiliBiliDanmakuArgs;
    webScoketUtils = WebScoketUtils(
      url: "wss://${args.serverHost}/sub",
      heartBeatTime: heartbeatTime,
      headers: args.cookie.isEmpty ? null : {"cookie": args.cookie},
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        connectionReady();
        onReady?.call();
        joinRoom(danmakuArgs);
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

  void joinRoom(BiliBiliDanmakuArgs args) {
    encodeAndSend({
      'kind': 'bili',
      'operation': 7,
      'text': utf16Bytes(
        json.encode({
          'uid': args.uid,
          'roomid': args.roomId,
          'protover': 3,
          'buvid': args.buvid,
          'platform': 'web',
          'type': 2,
          'key': args.token,
        }),
      ),
    });
  }

  @override
  void heartbeat() =>
      encodeAndSend({'kind': 'bili', 'operation': 2, 'text': utf16Bytes('')});
}
