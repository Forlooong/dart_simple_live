import 'dart:async';

import 'package:danmaku_native/danmaku_native.dart';
import '../common/http_client.dart';
import '../common/web_socket_util.dart';
import '../model/live_message.dart';
import 'native_live_danmaku.dart';

class DouyuDanmaku extends NativeLiveDanmaku {
  DouyuDanmaku() : super(2);
  @override
  int heartbeatTime = 45 * 1000;

  String serverUrl = "wss://danmuproxy.douyu.com:8506";

  final _giftNames = <int, String>{};
  String? _catalogRoom;
  bool _catalogRequested = false;

  @override
  LiveGiftMessage resolveGift(LiveGiftMessage gift) {
    if (gift.name.isNotEmpty || gift.itemId <= 0) return gift;
    final name = _giftNames[gift.itemId];
    if (name != null) return gift.withName(name);
    final room = _catalogRoom;
    if (!_catalogRequested && room != null && RegExp(r'^\d+$').hasMatch(room)) {
      _catalogRequested = true;
      unawaited(_loadGiftNames(room));
    }
    return gift;
  }

  Future<void> _loadGiftNames(String room) async {
    try {
      final response = await HttpClient.instance.getJson(
        'https://open.douyucdn.cn/api/RoomApi/room/$room',
      );
      if (_catalogRoom != room ||
          response is! Map ||
          response['data'] is! Map) {
        return;
      }
      final entries = response['data']['gift'];
      if (entries is! List) return;
      for (final entry in entries.take(2000)) {
        if (entry is! Map) continue;
        final id = int.tryParse(entry['id'].toString());
        final name = entry['name'];
        if (id != null && id > 0 && name is String && name.trim().isNotEmpty) {
          _giftNames[id] = name.trim();
        }
      }
    } catch (_) {
      // The gift ID remains available when the public catalogue is unavailable.
    }
  }

  @override
  Future start(dynamic args) async {
    if (!await initializeNative() || !nativeActive) return;
    final room = args.toString();
    if (_catalogRoom != room) {
      _catalogRoom = room;
      _giftNames.clear();
      _catalogRequested = false;
    }
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
