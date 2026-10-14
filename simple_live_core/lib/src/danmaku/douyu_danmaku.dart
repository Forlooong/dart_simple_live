import 'package:danmaku_native/danmaku_native.dart';
import '../common/web_socket_util.dart';
import 'native_live_danmaku.dart';

class DouyuDanmaku extends NativeLiveDanmaku {
  DouyuDanmaku() : super(2);
  @override
  int heartbeatTime = 45 * 1000;

  String serverUrl = "wss://danmuproxy.douyu.com:8506";

  @override
  Future start(dynamic args) async {
    if (!await initializeNative() || !nativeActive) return;
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        connectionReady();
        onReady?.call();
        joinRoom(args);
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

  void joinRoom(dynamic roomId) {
    encodeAndSend({
      'kind': 'douyu',
      'text': utf16Bytes('type@=loginreq/roomid@=$roomId/'),
    });
    encodeAndSend({
      'kind': 'douyu',
      'text': utf16Bytes('type@=joingroup/rid@=$roomId/gid@=-9999/'),
    });
  }

  @override
  void heartbeat() =>
      encodeAndSend({'kind': 'douyu', 'text': utf16Bytes('type@=mrkl/')});
}
