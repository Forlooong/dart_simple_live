import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/live_notifications/notification_store.dart';
import 'package:simple_live_app/services/live_notifications/notification_subscription.dart';

class _Storage extends LocalStorageService {
  String? failingKey;

  @override
  Future<void> setValue<T>(dynamic key, T value) async {
    if (key == failingKey) throw StateError('injected vault failure');
    await super.setValue(key, value);
  }
}

void main() {
  test('diagnostic exports contain only counts and fixed metadata', () {
    final text = Log.diagnosticSummary(
      [
        '[ERROR] Cookie: synthetic-secret',
        '[INFO] https://test.invalid/private?token=synthetic-secret',
        'old log has synthetic-secret',
      ],
      version: '1.0',
      platform: 'windows',
      now: DateTime.utc(2026),
    );
    expect(text, contains('ERROR: 1'));
    expect(text, contains('INFO: 1'));
    expect(text, isNot(contains('synthetic-secret')));
    expect(text, isNot(contains('test.invalid')));
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Storage storage;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('credential-safety-');
    Hive.init(directory.path);
    storage = _Storage()..settingsBox = await Hive.openBox('settings');
  });
  tearDown(() async {
    await storage.credentialChanges.close();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'WebDAV session changes are independent of legacy-key failures',
    () async {
      await storage.setValue(
        LocalStorageService.kWebDAVUri,
        'https://old.invalid',
      );
      await storage.setValue(LocalStorageService.kWebDAVUser, 'old');
      await storage.setValue(LocalStorageService.kWebDAVPassword, 'old-secret');
      expect(storage.webDavSession?.uri, 'https://old.invalid');

      storage.failingKey = 'WebDAVSession';
      await expectLater(
        storage.saveWebDavSession(
          uri: 'https://new.invalid',
          user: 'new',
          password: 'new-secret',
        ),
        throwsStateError,
      );
      expect(storage.webDavSession?.password, 'old-secret');

      storage.failingKey = LocalStorageService.kWebDAVPassword;
      await storage.saveWebDavSession(
        uri: 'https://new.invalid',
        user: 'new',
        password: 'new-secret',
      );
      final reopened = LocalStorageService()..settingsBox = storage.settingsBox;
      await reopened.migrateCredentials();
      expect(reopened.webDavSession?.uri, 'https://new.invalid');
      expect(reopened.webDavSession?.user, 'new');
      expect(reopened.webDavSession?.password, 'new-secret');

      await storage.clearWebDavSession();
      await reopened.migrateCredentials();
      expect(reopened.webDavSession, isNull);
      await reopened.credentialChanges.close();
    },
  );

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
      await store.writeConfig(NotificationConfig(rooms: rooms));
      expect(
        await File('${directory.path}/subscriptions.json').readAsString(),
        isNot(contains('CANARY')),
      );
      expect(await store.readPlatformCookie('bilibili'), 'CANARY-vault');
      await storage.setValue(
        LocalStorageService.kBilibiliCookie,
        'CANARY-updated',
      );
      expect(await store.readPlatformCookie('bilibili'), 'CANARY-updated');
    },
  );
}
