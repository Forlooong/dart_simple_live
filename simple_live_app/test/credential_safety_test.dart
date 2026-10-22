import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/live_notifications/notification_store.dart';
import 'package:simple_live_app/services/live_notifications/notification_subscription.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStorageService storage;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('credential-safety-');
    Hive.init(directory.path);
    storage = LocalStorageService()
      ..settingsBox = await Hive.openBox('settings');
  });
  tearDown(() async {
    await storage.credentialChanges.close();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'legacy credentials migrate once and never enter preferences or backup',
    () async {
      for (final key in LocalStorageService.credentialKeys) {
        await storage.settingsBox.put(key, 'CANARY-$key');
      }
      await storage.migrateCredentials();
      for (final key in LocalStorageService.credentialKeys) {
        expect(storage.getValue(key, ''), 'CANARY-$key');
        expect(
          await LocalStorageService.secureStorage.read(key: key),
          'CANARY-$key',
        );
        expect(storage.settingsBox.containsKey(key), isFalse);
      }
      expect(storage.exportSettings().toString(), isNot(contains('CANARY')));
      expect(
        String.fromCharCodes(
          await File(storage.settingsBox.path!).readAsBytes(),
        ),
        isNot(contains('CANARY')),
      );
      await storage.setValue(LocalStorageService.kBilibiliCookie, 'CANARY-new');
      await storage.settingsBox.put(
        LocalStorageService.kBilibiliCookie,
        'stale',
      );
      await storage.migrateCredentials();
      expect(
        storage.getValue(LocalStorageService.kBilibiliCookie, ''),
        'CANARY-new',
      );
      await storage.removeValue(LocalStorageService.kBilibiliCookie);
      expect(
        await LocalStorageService.secureStorage.read(
          key: LocalStorageService.kBilibiliCookie,
        ),
        '',
      );
    },
  );

  test(
    'interrupted credential deletion retries physical cleanup on restart',
    () async {
      const key = LocalStorageService.kBilibiliCookie;
      await storage.settingsBox.put(key, 'CANARY-interrupted');
      await LocalStorageService.secureStorage.write(
        key: key,
        value: 'CANARY-interrupted',
      );
      // Recreate a process exit after durable deletion but before compaction.
      await storage.settingsBox.put('_pendingCredentialCompaction', true);
      await storage.settingsBox.delete(key);
      await storage.settingsBox.flush();
      await storage.settingsBox.close();
      storage.settingsBox = await Hive.openBox('settings');
      expect(
        String.fromCharCodes(
          await File(storage.settingsBox.path!).readAsBytes(),
        ),
        contains('CANARY-interrupted'),
      );
      await storage.migrateCredentials();
      expect(storage.getValue(key, ''), 'CANARY-interrupted');
      expect(
        storage.settingsBox.containsKey('_pendingCredentialCompaction'),
        isFalse,
      );
      expect(
        String.fromCharCodes(
          await File(storage.settingsBox.path!).readAsBytes(),
        ),
        isNot(contains('CANARY-interrupted')),
      );
    },
  );

  test(
    'notification snapshots exclude secrets and workers read current vault',
    () async {
      final store = FileNotificationStore(directory);
      final rooms = [
        const NotificationSubscription(
          id: 'bilibili_1',
          siteId: 'bilibili',
          roomId: '1',
          userName: 'room',
          generation: 'g',
        ),
      ];
      await storage.setValue(
        LocalStorageService.kBilibiliCookie,
        'CANARY-vault',
      );
      await store.writeConfig(
        NotificationConfig(rooms: rooms, bilibiliCookie: 'CANARY-json'),
      );
      expect(
        await File('${directory.path}/subscriptions.json').readAsString(),
        isNot(contains('CANARY')),
      );
      expect((await store.readConfig()).bilibiliCookie, 'CANARY-vault');
      await storage.setValue(
        LocalStorageService.kBilibiliCookie,
        'CANARY-updated',
      );
      expect((await store.readConfig()).bilibiliCookie, 'CANARY-updated');
    },
  );
}
