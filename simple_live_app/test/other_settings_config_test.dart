import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/settings/other/other_settings_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class _Settings extends AppSettingsController {
  bool failRules = false;
  @override
  void reloadSettings({bool initializeLog = false}) {
    themeMode.value = LocalStorageService.instance.getValue(
      LocalStorageService.kThemeMode,
      0,
    );
  }

  @override
  Future<void> importShieldRules(
    Iterable<dynamic> data, {
    required bool replace,
  }) {
    if (failRules) throw StateError('injected write failure');
    return super.importShieldRules(data, replace: replace);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStorageService storage;
  late _Settings settings;
  late OtherSettingsController controller;

  Map<String, dynamic> configuration(
    Map config,
    Object shield, {
    int version = 2,
  }) => {
    'type': 'simple_live',
    'platform': Platform.operatingSystem,
    'version': version,
    'config': config,
    'shield': shield,
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('settings-config-');
    Hive.init(directory.path);
    storage = LocalStorageService()
      ..settingsBox = await Hive.openBox('settings')
      ..shieldBox = await Hive.openBox<String>('shield');
    Get.put(storage);
    settings = _Settings();
    Get.put<AppSettingsController>(settings);
    controller = OtherSettingsController();
  });
  tearDown(() async {
    Get.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'export excludes credentials, WebDAV destinations and internal journal',
    () async {
      const secret = 'PRIVATE_CONFIG_CANARY';
      await storage.settingsBox.putAll({
        LocalStorageService.kThemeMode: 1,
        LocalStorageService.kBilibiliCookie: secret,
        LocalStorageService.kDouyinCookie: secret,
        LocalStorageService.kWebDAVPassword: secret,
        LocalStorageService.kWebDAVUri: secret,
        LocalStorageService.kWebDAVUser: secret,
        '_pendingSettingsRestore': {'private': secret},
      });
      await storage.shieldBox.put('word', 'word');
      final exported = controller.configurationSnapshot();
      expect(exported['version'], 2);
      expect(exported['config'], {LocalStorageService.kThemeMode: 1});
      expect(exported['shield'], ['word']);
      expect(jsonEncode(exported), isNot(contains(secret)));
    },
  );

  test(
    'legacy import preserves sensitive settings, replaces preferences and awaits rules',
    () async {
      await storage.settingsBox.putAll({
        LocalStorageService.kThemeMode: 1,
        LocalStorageService.kVideoOutputDriver: 'custom',
        LocalStorageService.kBilibiliCookie: 'existing-account',
        LocalStorageService.kWebDAVUri: 'https://existing.invalid',
      });
      await storage.shieldBox.put('old', 'old');
      final result = await controller.restoreConfiguration(
        configuration(
          {
            LocalStorageService.kThemeMode: 2,
            LocalStorageService.kBilibiliCookie: 'imported-account',
            LocalStorageService.kWebDAVUri: 'https://imported.invalid',
            '_pendingSettingsRestore': {'previous': {}},
          },
          {'new': 'new'},
          version: 1,
        ),
      );
      expect(result.failed, isEmpty);
      expect(settings.themeMode.value, 2);
      expect(
        storage.settingsBox.containsKey(LocalStorageService.kVideoOutputDriver),
        isFalse,
      );
      expect(
        storage.settingsBox.get(LocalStorageService.kBilibiliCookie),
        'existing-account',
      );
      expect(
        storage.settingsBox.get(LocalStorageService.kWebDAVUri),
        'https://existing.invalid',
      );
      expect(storage.shieldBox.values, ['new']);
      expect(settings.shieldList, {'new'});
      await storage.shieldBox.close();
      storage.shieldBox = await Hive.openBox<String>('shield');
      expect(storage.shieldBox.values, ['new']);
    },
  );

  test(
    'a malformed second section cannot commit the valid first section',
    () async {
      await storage.settingsBox.put(LocalStorageService.kThemeMode, 1);
      await storage.shieldBox.put('old', 'old');
      for (final data in [
        configuration({LocalStorageService.kThemeMode: 2}, {'bad': 1}),
        configuration({LocalStorageService.kThemeMode: 'invalid'}, ['new']),
        configuration(
          {LocalStorageService.kThemeMode: 2},
          ['new'],
          version: 99,
        ),
      ]) {
        await expectLater(
          controller.restoreConfiguration(data),
          throwsFormatException,
        );
        expect(storage.settingsBox.get(LocalStorageService.kThemeMode), 1);
        expect(storage.shieldBox.values, ['old']);
      }
    },
  );

  test(
    'write failure reports the applied and incomplete categories separately',
    () async {
      await storage.shieldBox.put('old', 'old');
      settings.failRules = true;
      final result = await controller.restoreConfiguration(
        configuration({LocalStorageService.kThemeMode: 2}, ['new']),
      );
      expect(result.succeeded, ['常规偏好']);
      expect(result.failed, ['屏蔽词']);
      expect(storage.settingsBox.get(LocalStorageService.kThemeMode), 2);
      expect(storage.shieldBox.values, ['old']);
    },
  );

  test(
    'reset removes preference overrides while retaining account and sync state',
    () async {
      await storage.settingsBox.putAll({
        LocalStorageService.kThemeMode: 2,
        LocalStorageService.kVideoOutputDriver: 'custom',
        LocalStorageService.kBilibiliCookie: 'account',
        LocalStorageService.kWebDAVUser: 'sync-user',
        LocalStorageService.kLogEnable: true,
      });
      await storage.shieldBox.put('old', 'old');
      final result = await controller.restoreConfiguration(
        configuration({}, <String>[]),
      );
      expect(result.failed, isEmpty);
      expect(settings.themeMode.value, 0);
      expect(
        storage.settingsBox.containsKey(LocalStorageService.kVideoOutputDriver),
        isFalse,
      );
      expect(storage.shieldBox.isEmpty, isTrue);
      expect(
        storage.settingsBox.get(LocalStorageService.kBilibiliCookie),
        'account',
      );
      expect(
        storage.settingsBox.get(LocalStorageService.kWebDAVUser),
        'sync-user',
      );
      expect(storage.settingsBox.get(LocalStorageService.kLogEnable), isTrue);
    },
  );
}
