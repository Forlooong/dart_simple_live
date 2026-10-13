import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:workmanager/workmanager.dart';

import 'live_check_runner.dart';
import 'notification_store.dart';
import 'notification_subscription.dart';

const liveCheckTask = 'simple_live.selected_rooms.check.v1';
const liveCheckUniqueName = 'simple_live.selected_rooms.periodic.v1';
const liveNotificationChannel = AndroidNotificationChannel(
  'selected_room_live_v1',
  '关注直播间开播',
  description: '仅提醒你开启铃铛的直播间',
  importance: Importance.high,
);

const liveNotificationInitialization = InitializationSettings(
  android: AndroidInitializationSettings('ic_live_notification'),
);

Future<FileNotificationStore> openNotificationStore() async {
  final support = await getApplicationSupportDirectory();
  return FileNotificationStore(Directory('${support.path}/live_notifications'));
}

// String.hashCode is not stable across app launches or Dart runtimes.
int liveNotificationId(String roomKey) {
  final bytes = sha256.convert(utf8.encode(roomKey)).bytes;
  return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
      0x7fffffff;
}

/// Workmanager invokes this in its own engine, including after process death.
@pragma('vm:entry-point')
void liveNotificationCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (!Platform.isAndroid || task != liveCheckTask) return true;
    try {
      // No foreground services, player initialization or Hive access here.
      CoreLog.enableLog = false;
      final store = await openNotificationStore();
      final config = await store.readConfig();
      if (config.rooms.isEmpty) return true;
      final notifications = FlutterLocalNotificationsPlugin();
      await notifications.initialize(liveNotificationInitialization);
      final android = notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (await android?.areNotificationsEnabled() != true) return true;
      await android?.createNotificationChannel(liveNotificationChannel);
      final sites = <String, LiveSite>{
        'bilibili': BiliBiliSite()..cookie = config.bilibiliCookie,
        'douyu': DouyuSite(),
        'huya': HuyaSite(),
        'douyin': DouyinSite()..cookie = config.douyinCookie,
      };
      await LiveCheckRunner(
        store: store,
        check: (room) {
          final site = sites[room.siteId];
          if (site == null) throw const FormatException('Unsupported site');
          return site.getLiveStatus(roomId: room.roomId);
        },
        show: (room) => notifications.show(
          liveNotificationId(room.id),
          '${room.userName} 开播了',
          '点击进入直播间',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'selected_room_live_v1',
              '关注直播间开播',
              channelDescription: '仅提醒你开启铃铛的直播间',
              icon: 'ic_live_notification',
              importance: Importance.high,
              priority: Priority.high,
              // Reusing a stable ID replaces an older notification for this room.
              autoCancel: true,
              category: AndroidNotificationCategory.status,
            ),
          ),
          payload: jsonEncode(room.toJson()),
        ),
        cancel: (room) => notifications.cancel(liveNotificationId(room.id)),
      ).run();
      return true;
    } catch (_) {
      // Temporary filesystem/plugin errors should retry with WorkManager backoff.
      // Do not log platform responses or account cookies from a headless engine.
      return false;
    }
  });
}

NotificationSubscription? notificationRoomFromPayload(String? payload) {
  if (payload == null) return null;
  try {
    final room = NotificationSubscription.fromJson(
        Map<String, dynamic>.from(jsonDecode(payload)));
    if (!const {'bilibili', 'douyu', 'huya', 'douyin'}.contains(room.siteId) ||
        room.roomId.isEmpty ||
        room.id != '${room.siteId}_${room.roomId}') {
      return null;
    }
    return room;
  } catch (_) {
    return null;
  }
}
