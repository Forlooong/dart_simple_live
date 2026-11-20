import 'dart:convert';

class LiveAnchorItem {
  /// 房间ID
  final String roomId;
  final Uri? profile;
  final String? accountId;

  /// 封面
  final String avatar;

  /// 用户名
  final String userName;

  /// 直播中
  final bool liveStatus;
  final bool statusKnown;
  final String? roomTitle;

  LiveAnchorItem({
    required this.roomId,
    this.profile,
    this.accountId,
    required this.avatar,
    required this.userName,
    required this.liveStatus,
    this.statusKnown = true,
    this.roomTitle,
  });

  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "avatar": avatar,
      "userName": userName,
      "liveStatus": liveStatus,
    });
  }
}
