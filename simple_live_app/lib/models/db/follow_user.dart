import 'package:get/get.dart';
import 'package:hive/hive.dart';

part 'follow_user.g.dart';

@HiveType(typeId: 1)
class FollowUser {
  FollowUser({
    required this.id,
    required this.roomId,
    required this.siteId,
    required this.userName,
    required this.face,
    required this.addTime,
    this.tag = "全部",
    this.notifyLive = false,
  });

  ///id=siteId_roomId
  @HiveField(0)
  String id;

  @HiveField(1)
  String roomId;

  @HiveField(2)
  String siteId;

  @HiveField(3)
  String userName;

  @HiveField(4)
  String face;

  @HiveField(5)
  DateTime addTime;

  @HiveField(6)
  String tag;

  /// 仅为主动选择的关注房间发送开播提醒。
  @HiveField(7, defaultValue: false)
  bool notifyLive;

  /// 直播状态
  /// 0=未知(加载中) 1=未开播 2=直播中
  Rx<int> liveStatus = 0.obs;

  /// 开播时间戳
  String? liveStartTime;

  /// 旧版备份没有通知字段，导入时保留同一房间已有的通知选择。
  /// 覆盖同步的调用方需在清空数据库前保存 [existing]。
  factory FollowUser.fromJson(
    Map<String, dynamic> json, {
    FollowUser? existing,
  }) =>
      FollowUser(
        id: json['id'],
        roomId: json['roomId'],
        siteId: json['siteId'],
        userName: json['userName'],
        face: json['face'],
        addTime: DateTime.parse(json['addTime']),
        tag: json["tag"] ?? "全部",
        notifyLive: json.containsKey('notifyLive')
            ? json['notifyLive'] == true
            : existing?.id == json['id'] &&
                existing?.siteId == json['siteId'] &&
                existing?.roomId == json['roomId'] &&
                existing?.notifyLive == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'siteId': siteId,
        'userName': userName,
        'face': face,
        'addTime': addTime.toString(),
        'tag': tag,
        'notifyLive': notifyLive,
      };
}
