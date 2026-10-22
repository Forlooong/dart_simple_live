import 'dart:async';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show validateShieldRules;
import 'package:simple_live_tv_app/app/log.dart';

class LocalStorageService extends GetxService {
  static LocalStorageService get instance => Get.find<LocalStorageService>();

  /// 首次运行
  static const String kFirstRun = "FirstRun";

  /// 缩放模式
  static const String kPlayerScaleMode = "ScaleMode";

  /// 网站排序
  static const String kSiteSort = "SiteSort";

  /// 首页排序
  static const String kHomeSort = "HomeSort";

  /// 显示模式
  /// * [0] 跟随系统
  /// * [1] 浅色模式
  /// * [2] 深色模式
  static const String kThemeMode = "ThemeMode";

  /// DEBUG模式
  static const String kDebugModeKey = "DebugMode";

  /// 弹幕大小
  static const String kDanmuSize = "DanmuSize";

  /// 弹幕速度
  static const String kDanmuSpeed = "DanmuSpeed";

  /// 弹幕区域
  static const String kDanmuArea = "DanmuArea";

  /// 弹幕透明度
  static const String kDanmuOpacity = "DanmuOpacity";

  /// 弹幕描边大小
  static const String kDanmuStrokeWidth = "DanmuStrokeWidth";

  /// 弹幕-屏蔽滚动
  static const String kDanmuHideScroll = "DanmuHideScroll";

  /// 弹幕-屏蔽底部
  static const String kDanmuHideBottom = "DanmuHideBottom";

  /// 弹幕-屏蔽顶部
  static const String kDanmuHideTop = "DanmuHideTop";

  /// 弹幕-顶部边距
  static const String kDanmuTopMargin = "DanmuTopMargin";

  /// 弹幕-底部边距
  static const String kDanmuBottomMargin = "DanmuBottomMargin";

  /// 弹幕开启
  static const String kDanmuEnable = "DanmuEnable";

  /// 硬件解码
  static const String kHardwareDecode = "HardwareDecode";

  /// 聊天区文字大小
  static const String kChatTextSize = "ChatTextSize";

  /// 聊天区间隔
  static const String kChatTextGap = "ChatTextGap";

  /// 聊天区-气泡样式
  static const String kChatBubbleStyle = "ChatBubbleStyle";

  /// 播放清晰度，0=低，1=中，2=高
  static const String kQualityLevel = "QualityLevel";

  /// 蜂窝网络下播放清晰度，0=低，1=中，2=高
  static const String kQualityLevelCellular = "QualityLevelCellular";

  /// 开启定时关闭
  static const String kAutoExitEnable = "AutoExitEnable";

  /// 定时关闭时间（分钟）
  static const String kAutoExitDuration = "AutoExitDuration";

  /// 房间内定时关闭时间（分钟）
  /// 需要一个不同的 key，因为用户在房间内设置的倒计时和全局的可能不同。
  static const String kRoomAutoExitDuration = "RoomAutoExitDuration";

  /// 播放器兼容模式
  static const String kPlayerCompatMode = "PlayerCompatMode";

  /// 播放器后台自动暂停
  static const String kPlayerAutoPause = "PlayerAutoPause";

  /// 播放器缓冲区大小
  static const String kPlayerBufferSize = "PlayerBufferSize";

  /// 自动全屏
  static const String kAutoFullScreen = "AutoFullScreen";

  /// 小窗隐藏弹幕
  static const String kPIPHideDanmu = "PIPHideDanmu";

  /// 哔哩哔哩cookie
  static const String kBilibiliCookie = "BilibiliCookie";

  ///主题色
  static const String kStyleColor = "kStyleColor";

  ///动态取色
  static const String kIsDynamic = "kIsDynamic";

  /// 提示哔哩哔哩登录
  static const String kBilibiliLoginTip = "BilibiliLoginTip";

  /// 开启自动更新关注
  static const String kAutoUpdateFollowEnable = "AutoUpdateFollowEnable";

  /// 定时自动更新关注间隔（分钟）
  static const String kUpdateFollowDuration = "AutoUpdateFollowDuration";

  /// 开启多线程更新关注
  static const String kUpdateFollowThreadCount = "UpdateFollowThreadCount";

  static const credentialKeys = <String>{kBilibiliCookie};
  static const secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  final Map<String, String> _credentials = {};
  final credentialChanges = StreamController<String>.broadcast();
  Future<void> _credentialWrites = Future.value();

  Future<void> migrateCredentials() async {
    const pendingCompaction = '_pendingCredentialCompaction';
    var needsCompaction = settingsBox.get(pendingCompaction) == true;
    for (final key in credentialKeys) {
      var value = await secureStorage.read(key: key);
      final legacy = settingsBox.get(key);
      if (value == null && legacy is String) {
        await secureStorage.write(key: key, value: legacy);
        value = legacy;
      }
      if (value != null) _credentials[key] = value;
      // Only remove the old copy after platform storage confirms the write.
      if (settingsBox.containsKey(key)) {
        // Persist intent before removing the key: a crash between deletion and
        // compaction must not leave obsolete plaintext records indefinitely.
        if (!needsCompaction) {
          await settingsBox.put(pendingCompaction, true);
          await settingsBox.flush();
          needsCompaction = true;
        }
        await settingsBox.delete(key);
      }
    }
    await settingsBox.flush();
    // Compact migrated live storage after the vault write succeeds. Historical
    // backups and old logs are retained for user-controlled cleanup.
    if (needsCompaction) {
      await settingsBox.compact();
      await settingsBox.delete(pendingCompaction);
      await settingsBox.flush();
    }
  }

  Future<void> _shieldWrites = Future.value();

  Future<Set<String>> updateShieldRules(
    Iterable<dynamic> data, {
    required bool replace,
    String? remove,
  }) {
    final incoming = validateShieldRules(data);
    final result = _shieldWrites.then((_) async {
      await recoverShieldRules();
      final previous = Map<dynamic, String>.from(shieldBox.toMap());
      final next = <String>{if (!replace) ...previous.values, ...incoming};
      if (remove != null) next.remove(remove);
      if (remove == null) validateShieldRules(next);
      await settingsBox.put('_pendingShieldRestore', previous);
      await settingsBox.flush();
      // Hive deletes append tombstones; compact the migrated live box so old
      // credential values are not retained in its obsolete records.
      try {
        await shieldBox.putAll({for (final rule in next) rule: rule});
        await shieldBox.deleteAll(
          shieldBox.keys.where((key) => !next.contains(key)).toList(),
        );
        await shieldBox.flush();
        await settingsBox.delete('_pendingShieldRestore');
        await settingsBox.flush();
        // Hive deletes append tombstones; compact the migrated live box so old
        // credential values are not retained in its obsolete records.
      } catch (_) {
        await settingsBox.put('_pendingShieldRestore', previous);
        await settingsBox.flush();
        // Hive deletes append tombstones; compact the migrated live box so old
        // credential values are not retained in its obsolete records.
        await recoverShieldRules();
        rethrow;
      }
      return next;
    });
    _shieldWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> recoverShieldRules() async {
    final previous = settingsBox.get('_pendingShieldRestore');
    if (previous == null) return;
    final records = Map<dynamic, String>.from(previous as Map);
    await shieldBox.putAll(records);
    await shieldBox.deleteAll(
      shieldBox.keys.where((key) => !records.containsKey(key)).toList(),
    );
    await shieldBox.flush();
    await settingsBox.delete('_pendingShieldRestore');
    await settingsBox.flush();
  }

  late Box settingsBox;
  late Box<String> shieldBox;

  Future init() async {
    settingsBox = await Hive.openBox("TVLocalStorage");
    await migrateCredentials();
    shieldBox = await Hive.openBox("TVDanmuShield");
    await recoverShieldRules();
  }

  T getValue<T>(dynamic key, T defaultValue) {
    try {
      final value =
          (credentialKeys.contains(key)
                  ? (_credentials[key] ?? defaultValue)
                  : settingsBox.get(key, defaultValue: defaultValue))
              as T;
      return value;
    } catch (e) {
      Log.logPrint(e);
      return defaultValue;
    }
  }

  Future setValue<T>(dynamic key, T value) async {
    if (credentialKeys.contains(key)) {
      if (value is! String) throw const FormatException('凭据必须为字符串');
      final write = _credentialWrites.then((_) async {
        await secureStorage.write(key: key as String, value: value);
        _credentials[key] = value;
        credentialChanges.add(key);
      });
      _credentialWrites = write.catchError((Object _) {});
      return await write;
    }
    return await settingsBox.put(key, value);
  }

  Future removeValue<T>(dynamic key) async {
    if (credentialKeys.contains(key)) return setValue(key, '');
    return await settingsBox.delete(key);
  }
}
