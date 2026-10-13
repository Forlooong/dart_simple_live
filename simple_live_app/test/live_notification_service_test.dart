import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/live_notification_service.dart';
import 'package:simple_live_app/services/live_notifications/android_live_notifications.dart';
import 'package:simple_live_app/services/live_notifications/notification_store.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:workmanager/workmanager.dart';
import 'package:workmanager_android/workmanager_android.dart';

const _notificationChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');

class _TemporaryPathProvider extends PathProviderPlatform {
  _TemporaryPathProvider(this.directory);
  final Directory directory;

  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
}

BasicMessageChannel<Object?> _workChannel(String method) => BasicMessageChannel(
      'dev.flutter.pigeon.workmanager_platform_interface.WorkmanagerHostApi.$method',
      WorkmanagerHostApi.pigeonChannelCodec,
    );

FollowUser _follow(String roomId) => FollowUser(
      id: 'bilibili_$roomId',
      siteId: 'bilibili',
      roomId: roomId,
      userName: '主播 $roomId',
      face: '',
      addTime: DateTime(2026, 10, 13),
    );

// Keep the production plugin implementations, serialization and service intact;
// only replace the native endpoints that do not exist in a desktop test runner.
class _NativeEndpoints {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final initializations = <InitializeRequest>[];
  final registrations = <PeriodicTaskRequest>[];
  final cancelledTasks = <String>[];
  bool permissionGranted = true;
  bool notificationsEnabled = true;
  bool rejectRegistrations = false;
  Completer<bool>? permissionReply;
  Completer<void>? permissionRequested;
  Completer<void>? nextCancellation;
  Completer<void>? nextRegistration;

  void install() {
    messenger.setMockMethodCallHandler(_notificationChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'getNotificationAppLaunchDetails':
          return {'notificationLaunchedApp': false};
        case 'requestNotificationsPermission':
          permissionRequested?.complete();
          permissionRequested = null;
          return permissionReply == null
              ? permissionGranted
              : await permissionReply!.future;
        case 'areNotificationsEnabled':
          return notificationsEnabled;
        case 'createNotificationChannel':
        case 'cancel':
          return null;
        default:
          throw MissingPluginException(
              'Unexpected notification method: ${call.method}');
      }
    });
    messenger.setMockDecodedMessageHandler<Object?>(_workChannel('initialize'),
        (message) async {
      initializations.add((message! as List).single as InitializeRequest);
      return <Object?>[null];
    });
    messenger.setMockDecodedMessageHandler<Object?>(
        _workChannel('registerPeriodicTask'), (message) async {
      registrations.add((message! as List).single as PeriodicTaskRequest);
      if (rejectRegistrations) {
        return <Object?>['schedule-failed', 'Unavailable', null];
      }
      nextRegistration?.complete();
      nextRegistration = null;
      return <Object?>[null];
    });
    messenger.setMockDecodedMessageHandler<Object?>(
        _workChannel('cancelByUniqueName'), (message) async {
      cancelledTasks.add((message! as List).single as String);
      nextCancellation?.complete();
      nextCancellation = null;
      return <Object?>[null];
    });
  }

  void clearActivity() {
    calls.clear();
    registrations.clear();
    cancelledTasks.clear();
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(_notificationChannel, null);
    for (final method in [
      'initialize',
      'registerPeriodicTask',
      'cancelByUniqueName'
    ]) {
      messenger.setMockDecodedMessageHandler<Object?>(
          _workChannel(method), null);
    }
  }

  Iterable<int> get cancelledNotifications => calls
      .where((call) => call.method == 'cancel')
      .map((call) => (call.arguments as Map)['id'] as int);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Workmanager wire tags match the pinned Android native codec', () {
    // workmanager_android 0.9.0+2's generated WorkmanagerApi.g.kt maps
    // InitializeRequest -> 137 and PeriodicTaskRequest -> 139 (10 fields).
    // A mock that decodes with the same Dart codec alone would hide the
    // incompatible 0.9.4 platform interface, which shifted these wire tags.
    const codec = WorkmanagerHostApi.pigeonChannelCodec;
    expect(
        codec.encodeMessage(InitializeRequest(callbackHandle: 1))!.getUint8(0),
        137);
    final periodic = PeriodicTaskRequest(
      uniqueName: 'test',
      taskName: 'check',
      frequencySeconds: 900,
    );
    expect(codec.encodeMessage(periodic)!.getUint8(0), 139);
    expect(periodic.encode() as List, hasLength(10));
  });

  group('LiveNotificationService with real Hive and plugin channels', () {
    late Directory directory;
    late DBService database;
    late LocalStorageService storage;
    late LiveNotificationService service;
    late FileNotificationStore snapshots;
    late _NativeEndpoints native;
    late FollowUser room;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('simple-live-service-');
      addTearDown(() async {
        await directory.delete(recursive: true);
      });
      Hive.init(directory.path);
      addTearDown(() async {
        await Hive.close();
        Get.reset();
      });
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(FollowUserAdapter());
      }
      database = DBService()
        ..followBox = await Hive.openBox<FollowUser>('notification_follows');
      storage = LocalStorageService()
        ..settingsBox = await Hive.openBox<dynamic>('notification_settings');
      Get.put(database);
      Get.put(storage);
      room = _follow('123');
      await database.followBox.put(room.id, room);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final previousWorkmanager = WorkmanagerPlatform.instance;
      final previousPaths = PathProviderPlatform.instance;
      addTearDown(() {
        WorkmanagerPlatform.instance = previousWorkmanager;
        PathProviderPlatform.instance = previousPaths;
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        debugDefaultTargetPlatformOverride = null;
      });
      PathProviderPlatform.instance = _TemporaryPathProvider(directory);
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      WorkmanagerAndroid.registerWith();
      native = _NativeEndpoints()..install();
      addTearDown(native.uninstall);
      service = LiveNotificationService(androidSupported: true);
      addTearDown(service.onClose);
      snapshots = FileNotificationStore(
          Directory('${directory.path}/live_notifications'));
      await service.init();
      native.clearActivity();
    });

    for (final permissionGranted in [false, true]) {
      test(
          'permission denial does not save or schedule (request: $permissionGranted)',
          () async {
        native.permissionGranted = permissionGranted;
        native.notificationsEnabled = false;
        await expectLater(
          service.toggle(room),
          throwsA(isA<Exception>().having(
              (error) => error.toString(), 'message', contains('未获得通知权限'))),
        );
        expect(database.followBox.get(room.id)!.notifyLive, isFalse);
        expect((await snapshots.readConfig()).rooms, isEmpty);
        expect(native.registrations, isEmpty);
        expect(native.calls.map((call) => call.method),
            contains('requestNotificationsPermission'));
        if (permissionGranted) {
          expect(native.calls.map((call) => call.method),
              contains('areNotificationsEnabled'));
        }
      });
    }

    test(
        'enabling persists the selection and schedules unique connected 15-minute work',
        () async {
      expect(await service.toggle(room), isTrue);
      expect(database.followBox.get(room.id)!.notifyLive, isTrue);
      final config = await snapshots.readConfig();
      expect(config.rooms.map((room) => room.id), [room.id]);
      expect(config.rooms.single.generation, isNotEmpty);
      expect(native.initializations, hasLength(1));
      expect(native.registrations, isNotEmpty);
      for (final request in native.registrations) {
        expect(request.uniqueName, liveCheckUniqueName);
        expect(request.taskName, liveCheckTask);
        expect(request.frequencySeconds, 900);
        expect(request.existingWorkPolicy, ExistingPeriodicWorkPolicy.keep);
        expect(request.constraints?.networkType, NetworkType.connected);
        expect(request.inputData, isNull);
      }
      final generation = config.rooms.single.generation;
      native.nextRegistration = Completer<void>();
      final synchronized = native.nextRegistration!.future;
      await storage.settingsBox
          .put(LocalStorageService.kBilibiliCookie, 'updated cookie');
      await synchronized.timeout(const Duration(seconds: 2));
      final updated = await snapshots.readConfig();
      expect(updated.rooms.single.generation, generation);
      expect(updated.bilibiliCookie, 'updated cookie');
    });

    test('turning off the last selection cancels its alert and periodic task',
        () async {
      await service.toggle(room);
      native.clearActivity();
      expect(await service.toggle(room), isFalse);
      expect(database.followBox.get(room.id)!.notifyLive, isFalse);
      expect((await snapshots.readConfig()).rooms, isEmpty);
      expect(
          native.cancelledNotifications, contains(liveNotificationId(room.id)));
      expect(native.cancelledTasks, contains(liveCheckUniqueName));
      expect(native.registrations, isEmpty);
      expect(native.calls.map((call) => call.method),
          isNot(contains('requestNotificationsPermission')));
    });

    test('unfollowing the last selection cancels work through the Hive watcher',
        () async {
      await service.toggle(room);
      native.clearActivity();
      native.nextCancellation = Completer<void>();
      final cancelled = native.nextCancellation!.future;
      await database.deleteFollow(room.id);
      await cancelled.timeout(const Duration(seconds: 2));
      expect((await snapshots.readConfig()).rooms, isEmpty);
      expect(native.cancelledNotifications, [liveNotificationId(room.id)]);
      expect(native.cancelledTasks, [liveCheckUniqueName]);
    });

    test(
        'unfollowing one selected room preserves the others and shared periodic work',
        () async {
      await service.toggle(room);
      final other = _follow('456');
      await database.followBox.put(other.id, other);
      await service.toggle(other);
      native.clearActivity();
      native.nextRegistration = Completer<void>();
      final synchronized = native.nextRegistration!.future;
      await database.deleteFollow(room.id);
      await synchronized.timeout(const Duration(seconds: 2));
      expect((await snapshots.readConfig()).rooms.map((room) => room.id),
          [other.id]);
      expect(native.cancelledNotifications, [liveNotificationId(room.id)]);
      expect(native.cancelledTasks, isEmpty);
      expect(native.registrations.single.uniqueName, liveCheckUniqueName);
      expect(native.registrations.single.existingWorkPolicy,
          ExistingPeriodicWorkPolicy.keep);
    });

    test(
        'unfollow while the permission prompt is pending cannot resurrect a selection',
        () async {
      native.permissionReply = Completer<bool>();
      native.permissionRequested = Completer<void>();
      final requested = native.permissionRequested!.future;
      final result = expectLater(
        service.toggle(room),
        throwsA(isA<Exception>()
            .having((error) => error.toString(), 'message', contains('已取消关注'))),
      );
      await requested;
      native.nextCancellation = Completer<void>();
      final cancelled = native.nextCancellation!.future;
      await database.deleteFollow(room.id);
      await cancelled.timeout(const Duration(seconds: 2));
      native.permissionReply!.complete(true);
      await result;
      expect(database.followBox.containsKey(room.id), isFalse);
      expect((await snapshots.readConfig()).rooms, isEmpty);
      expect(native.registrations, isEmpty);
    });

    test(
        'a native scheduling failure rolls back the saved preference and snapshot',
        () async {
      native.rejectRegistrations = true;
      await expectLater(service.toggle(room), throwsA(isA<Exception>()));
      expect(database.followBox.get(room.id)!.notifyLive, isFalse);
      expect((await snapshots.readConfig()).rooms, isEmpty);
      expect(native.registrations, isNotEmpty);
      expect(native.cancelledTasks, contains(liveCheckUniqueName));
    });
  });
}
