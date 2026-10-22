import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart';

import 'live_notifications/android_live_notifications.dart';
import 'live_notifications/notification_navigation.dart';
import 'live_notifications/notification_store.dart';
import 'live_notifications/notification_subscription.dart';

class LiveNotificationService extends GetxService with WidgetsBindingObserver {
  LiveNotificationService({bool? androidSupported})
    : _androidSupported = androidSupported ?? Platform.isAndroid;

  static LiveNotificationService get instance => Get.find();

  final bool _androidSupported;
  final _notifications = FlutterLocalNotificationsPlugin();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late FileNotificationStore _store;
  Future<void> _writes = Future.value();
  bool _initialized = false;
  bool _navigationReady = false;
  bool _openingRoom = false;
  NotificationSubscription? _pendingRoom;

  Future<void> init() async {
    if (!_androidSupported || _initialized) return;
    _store = await openNotificationStore();
    await _notifications.initialize(
      liveNotificationInitialization,
      onDidReceiveNotificationResponse: (response) {
        _pendingRoom = notificationRoomFromPayload(response.payload);
        unawaited(_openPendingRoom());
      },
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(liveNotificationChannel);
    await Workmanager().initialize(liveNotificationCallbackDispatcher);
    final launch = await _notifications.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      _pendingRoom = notificationRoomFromPayload(
        launch?.notificationResponse?.payload,
      );
    }
    WidgetsBinding.instance.addObserver(this);
    _subscriptions.add(
      DBService.instance.followBox.watch().listen((_) {
        _syncQuietly();
      }),
    );
    _subscriptions.add(
      LocalStorageService.instance.credentialChanges.stream.listen((_) {
        _syncQuietly();
      }),
    );
    _initialized = true;
    await _enqueueSync();
  }

  void _syncQuietly() {
    unawaited(
      _enqueueSync().catchError((Object error) {
        Log.w('开播提醒同步失败，将在下次操作或启动时重试');
      }),
    );
  }

  Future<void> _enqueueSync() {
    // Capture immediately: an off/on pair must not be coalesced into an unchanged
    // subscription, otherwise stale in-flight results could notify a new opt-in.
    final rooms = DBService.instance.followBox.values
        .where(
          (room) => room.notifyLive && Sites.allSites.containsKey(room.siteId),
        )
        .map(
          (room) => (
            id: room.id,
            siteId: room.siteId,
            roomId: room.roomId,
            name: room.userName,
          ),
        )
        .toList();
    // The UI is the only config writer, and its writes must remain ordered.
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final old = await _store.readConfig();
      final previous = {for (final room in old.rooms) room.id: room};
      final selected = rooms.map((room) {
        final before = previous[room.id];
        return NotificationSubscription(
          id: room.id,
          siteId: room.siteId,
          roomId: room.roomId,
          userName: room.name,
          generation:
              before?.siteId == room.siteId && before?.roomId == room.roomId
              ? before!.generation
              : const Uuid().v4(),
        );
      }).toList();
      await _store.writeConfig(NotificationConfig(rooms: selected));
      for (final removed in old.rooms.where(
        (oldRoom) => !selected.any((room) => room.id == oldRoom.id),
      )) {
        await _notifications.cancel(liveNotificationId(removed.id));
      }
      if (selected.isEmpty) {
        await Workmanager().cancelByUniqueName(liveCheckUniqueName);
      } else {
        await Workmanager().registerPeriodicTask(
          liveCheckUniqueName,
          liveCheckTask,
          frequency: const Duration(minutes: 15),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      }
    });
    return _writes;
  }

  Future<bool> toggle(FollowUser item) async {
    if (!_androidSupported) return false;
    try {
      await init();
      final box = DBService.instance.followBox;
      final current = box.get(item.id);
      if (current == null) throw Exception('直播间已取消关注');
      final enabled = !current.notifyLive;
      if (enabled) {
        final android = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final granted = await android?.requestNotificationsPermission();
        if (granted != true ||
            await android?.areNotificationsEnabled() != true) {
          throw Exception('未获得通知权限，请在系统设置中允许 Simple Live 通知');
        }
      }
      // The permission dialog may have outlived a sync or an unfollow.
      final change = await DBService.instance.setFollowNotification(
        item.id,
        enabled,
      );
      try {
        await _enqueueSync();
      } catch (_) {
        await DBService.instance.rollbackFollowNotification(
          change.saved,
          change.previous,
        );
        await _enqueueSync();
        rethrow;
      }
      return enabled;
    } on Exception catch (error) {
      if (error.toString().startsWith('Exception: ')) rethrow;
      throw Exception('暂时无法更新开播提醒，请稍后重试');
    } catch (_) {
      throw Exception('暂时无法更新开播提醒，请稍后重试');
    }
  }

  /// Called only after the app's first frame has created its navigator.
  void markNavigationReady() {
    _navigationReady = true;
    unawaited(_openPendingRoom());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_openPendingRoom());
    }
  }

  Future<void> _openPendingRoom() async {
    if (!_navigationReady ||
        _openingRoom ||
        _pendingRoom == null ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed)) {
      return;
    }
    _openingRoom = true;
    try {
      while (_pendingRoom != null) {
        // A popped GetX route retains its controller until its transition ends.
        // Wait for disposal before looking up or creating a room controller.
        await liveNotificationNavigationObserver.waitForRetiringLiveRooms();
        if (!await AppNavigator.waitForPlayerCleanup(
          PlayerController.pendingCleanup,
        )) {
          _pendingRoom = null;
          break;
        }
        if (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          break;
        }
        if (_pendingRoom == null) break;
        final room = _pendingRoom!;
        _pendingRoom = null;
        final site = Sites.allSites[room.siteId];
        if (site == null) continue;
        final hasLiveRoom = liveNotificationNavigationObserver.revealLiveRoom();
        if (hasLiveRoom && Get.isRegistered<LiveRoomController>()) {
          final controller = Get.find<LiveRoomController>();
          if (!controller.playerClosing) {
            // Reuse the active room so two players never share the GetX singleton.
            controller.resetRoom(site, room.roomId);
            continue;
          }
        }
        if (hasLiveRoom) {
          // A closing player must not be reused while its route is still visible.
          await liveNotificationNavigationObserver.removeLiveRoom();
          _pendingRoom ??= room;
          continue;
        }
        AppNavigator.toLiveRoomDetail(site: site, roomId: room.roomId);
      }
    } catch (_) {
      Log.w('无法打开开播通知中的直播间');
    } finally {
      _openingRoom = false;
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.onClose();
  }
}
