/// A UI-owned snapshot. Background isolates never open the UI's Hive boxes.
class NotificationSubscription {
  const NotificationSubscription({
    required this.id,
    required this.siteId,
    required this.roomId,
    required this.userName,
    required this.generation,
  });

  final String id;
  final String siteId;
  final String roomId;
  final String userName;
  // Changes after opt-out/re-subscribe, even for the same room.
  final String generation;

  factory NotificationSubscription.fromJson(Map<String, dynamic> json) =>
      NotificationSubscription(
        id: json['id'] as String,
        siteId: json['siteId'] as String,
        roomId: json['roomId'] as String,
        userName: json['userName'] as String,
        generation: json['generation'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'siteId': siteId,
        'roomId': roomId,
        'userName': userName,
        'generation': generation,
      };
}

class NotificationConfig {
  const NotificationConfig({
    this.rooms = const [],
    this.bilibiliCookie = '',
    this.douyinCookie = '',
  });

  final List<NotificationSubscription> rooms;
  final String bilibiliCookie;
  final String douyinCookie;

  bool contains(NotificationSubscription room) => rooms.any((current) =>
      current.id == room.id && current.generation == room.generation);

  factory NotificationConfig.fromJson(Map<String, dynamic> json) =>
      NotificationConfig(
        rooms: (json['rooms'] as List)
            .map((room) => NotificationSubscription.fromJson(
                Map<String, dynamic>.from(room as Map)))
            .toList(),
        bilibiliCookie: json['bilibiliCookie'] as String? ?? '',
        douyinCookie: json['douyinCookie'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'version': 1,
        'rooms': rooms.map((room) => room.toJson()).toList(),
        'bilibiliCookie': bilibiliCookie,
        'douyinCookie': douyinCookie,
      };
}
