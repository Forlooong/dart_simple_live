import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/follow_user/live_reminder_center.dart';
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
  bool _pendingCenter = false;

  void _selectPayload(String? payload) {
    _pendingCenter = payload == liveReminderSummaryPayload;
    _pendingRoom = notificationRoomFromPayload(payload);
  }

  Future<void> init() async {
    if (!_androidSupported || _initialized) return;
    _store = await openNotificationStore();
    await _notifications.initialize(
      liveNotificationInitialization,
      onDidReceiveNotificationResponse: (response) {
        _selectPayload(response.payload);
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
      _selectPayload(launch?.notificationResponse?.payload);
    }
    WidgetsBinding.instance.addObserver(this);
    _subscriptions.add(
      DBService.instance.followBox.watch().listen((_) {
        _syncQuietly();
      }),
    );
    _subscriptions.add(
      LocalStorageService.instance.credentialChanges.stream.listen((key) {
        final site = switch (key) {
          LocalStorageService.kBilibiliCookie => 'bilibili',
          LocalStorageService.kDouyinCookie => 'douyin',
          _ => null,
        };
        if (site != null) _syncQuietly(credentialSite: site);
      }),
    );
    _initialized = true;
    await _enqueueSync();
  }

  void _syncQuietly({String? credentialSite}) {
    unawaited(
      _enqueueSync(credentialSite: credentialSite).catchError((Object error) {
        Log.w('开播提醒同步失败，将在下次操作或启动时重试');
      }),
    );
  }

  Future<void> _enqueueSync({String? credentialSite}) {
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
      await _store.writeConfig(
        NotificationConfig(
          rooms: selected,
          quietHours: old.quietHours,
          credentialRevisions: {
            ...old.credentialRevisions,
            if (credentialSite != null)
              credentialSite: old.credentialRevision(credentialSite) + 1,
          },
          preferences: {
            for (final room in selected)
              if (old.preferences.containsKey(room.generation))
                room.generation: old.preferences[room.generation]!,
          },
        ),
      );
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

  Future<List<String>> platformDiagnostics() async {
    if (!_initialized) return ['后台检查尚未初始化'];
    try {
      final config = await _store.readConfig();
      final state = await _store.readState();
      final platforms = state['platforms'] as Map? ?? {};
      final sites = config.rooms.map((room) => room.siteId).toSet();
      final output = <String>[];
      for (final site in sites) {
        final status = platforms[site] as Map? ?? {};
        final last = DateTime.tryParse(status['lastSuccess'] as String? ?? '');
        final name = Sites.allSites[site]?.liveSite.name ?? site;
        final age =
            last == null ||
                DateTime.now().difference(last) < const Duration(hours: 1)
            ? ''
            : '（已过期）';
        final time = last == null
            ? '暂无成功记录'
            : '最近成功 ${last.toLocal().toString().substring(0, 16)}$age';
        final issue = describePlatformIssue(status);
        final error = issue == null ? '' : ' · $issue';
        final coverage = status.isEmpty
            ? ''
            : ' · 成功 ${status['succeeded']}/${status['checked']}，订阅 ${status['selected']}';
        output.add('$name · $time$coverage$error');
      }
      return output.isEmpty ? ['暂无开播提醒订阅'] : output;
    } catch (_) {
      return ['暂时无法读取后台检查记录'];
    }
  }

  static String? describePlatformIssue(Map? status) {
    final error = switch (status?['error']) {
      'timeout' => '检查超时',
      'authRequired' => '登录失效',
      'rateLimited' => '平台限流',
      'schemaChanged' => '响应格式异常',
      'transport' => '网络异常',
      'unknown' => '检查失败',
      _ => null,
    };
    if (error == null) return null;
    return status?['succeeded'] == 0 ? '平台暂不可用（$error）' : '部分检查失败（$error）';
  }

  Future<({NotificationConfig config, Map<String, dynamic> state})>
  reminderSnapshot() async {
    await init();
    return (config: await _store.readConfig(), state: await _store.readState());
  }

  Future<void> _editReminderConfig(
    NotificationConfig Function(NotificationConfig) edit,
  ) async {
    await init();
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final config = await _store.readConfig();
      await _store.writeConfig(edit(config));
    });
    return _writes;
  }

  Future<void> setQuietHours(QuietHours? hours) => _editReminderConfig(
    (config) => NotificationConfig(
      rooms: config.rooms,
      quietHours: hours,
      preferences: config.preferences,
      credentialRevisions: config.credentialRevisions,
    ),
  );

  Future<void> setReminderPreference(
    NotificationSubscription room,
    ReminderPreference preference,
  ) => _editReminderConfig((config) {
    if (!config.contains(room)) return config;
    return NotificationConfig(
      rooms: config.rooms,
      quietHours: config.quietHours,
      credentialRevisions: config.credentialRevisions,
      preferences: {...config.preferences, room.generation: preference},
    );
  });

  Future<void> disableReminder(NotificationSubscription room) async {
    if (!(await _store.readConfig()).contains(room)) return;
    final item = DBService.instance.followBox.get(room.id);
    if (item != null && item.notifyLive) await toggle(item);
  }

  void openReminderRoom(NotificationSubscription room) {
    _pendingRoom = room;
    unawaited(_openPendingRoom());
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
        (_pendingRoom == null && !_pendingCenter) ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed)) {
      return;
    }
    _openingRoom = true;
    try {
      if (_pendingCenter) {
        _pendingCenter = false;
        unawaited(
          Get.to<void>(() => const LiveReminderCenter()) ??
              Future<void>.value(),
        );
        return;
      }
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
