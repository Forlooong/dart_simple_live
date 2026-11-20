import 'dart:convert';

class LiveRoomItem {
  /// 房间ID
  final String roomId;
  final Uri? profile;
  final String? accountId;

  /// 标题
  final String title;

  /// 封面
  final String cover;

  /// 用户名
  final String userName;

  /// 人气/在线人数
  final int online;

  /// 平台是否返回了在线人数；未返回时 [online] 不代表真实人数
  final bool onlineKnown;
  final bool? liveStatus;
  LiveRoomItem({
    required this.roomId,
    this.profile,
    this.accountId,
    required this.title,
    required this.cover,
    required this.userName,
    this.online = 0,
    this.onlineKnown = true,
    this.liveStatus,
  });

  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "title": title,
      "cover": cover,
      "userName": userName,
      "online": online,
    });
  }
}
