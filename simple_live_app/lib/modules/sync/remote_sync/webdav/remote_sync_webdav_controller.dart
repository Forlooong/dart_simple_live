import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show validateShieldRules;

class RemoteSyncWebDAVController extends BaseController {
  // ui
  var passwordVisible = true.obs;
  // ui-用户选择是否同步
  var isSyncFollows = true.obs;
  var isSyncHistories = true.obs;
  var isSyncBlockWord = true.obs;
  var isSyncBilibiliAccount = false.obs;
  bool _busy = false;

  late DAVClient davClient;
  var user = "--".obs;
  var lastRecoverTime = "--".obs;
  var lastUploadTime = "--".obs;

  final _userFollowJsonName = 'SimpleLive_follows.json';
  final _userHistoriesJsonName = 'SimpleLive_histories.json';
  final _userBlockedWordJsonName = 'SimpleLive_blocked_word.json';
  final _userBilibiliAccountJsonName = 'SimpleLive_bilibili_account.json';
  final _userSettingsJsonName = 'SimpleLive_Settings.json';
  final _userTagsJsonName = 'SimpleLive_Tags.json';

  @override
  void onInit() {
    doWebDAVInit();
    super.onInit();
  }

  // webDAV 逻辑
  // 初始化webDAV
  void doWebDAVInit() {
    var uri = LocalStorageService.instance.getValue(
      LocalStorageService.kWebDAVUri,
      "",
    );
    if (uri.isEmpty) {
      notLogin.value = true;
    } else {
      user.value = LocalStorageService.instance.getValue(
        LocalStorageService.kWebDAVUser,
        "",
      );
      var password = LocalStorageService.instance.getValue(
        LocalStorageService.kWebDAVPassword,
        "",
      );
      davClient = DAVClient(uri, user.value, password);
      // 从未同步过默认为最新数据
      lastRecoverTime.value = Utils.parseTime(
        DateTime.fromMillisecondsSinceEpoch(
          LocalStorageService.instance.getValue(
            LocalStorageService.kWebDAVLastRecoverTime,
            DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      lastUploadTime.value = Utils.parseTime(
        DateTime.fromMillisecondsSinceEpoch(
          LocalStorageService.instance.getValue(
            LocalStorageService.kWebDAVLastUploadTime,
            DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      checkIsLogin();
    }
  }

  // 检查webDAV登录状态
  Future<void> checkIsLogin() async {
    try {
      // 返回登录结果
      bool value = await davClient.pingCompleter.future;
      notLogin.value = !value;
    } catch (e) {
      Log.e("$e", StackTrace.current);
      notLogin.value = true;
    }
  }

  // WebDAV登录
  Future<void> doWebDAVLogin(
    String webDAVUri,
    String webDAVUser,
    String webDAVPassword,
  ) async {
    // 确认登录
    davClient = DAVClient(webDAVUri, webDAVUser, webDAVPassword);
    await checkIsLogin();
    if (!notLogin.value) {
      // 保存到本地
      await LocalStorageService.instance.setValue(
        LocalStorageService.kWebDAVUri,
        webDAVUri,
      );
      await LocalStorageService.instance.setValue(
        LocalStorageService.kWebDAVUser,
        webDAVUser,
      );
      user.value = webDAVUser;
      await LocalStorageService.instance.setValue(
        LocalStorageService.kWebDAVPassword,
        webDAVPassword,
      );
      Get.back();
      SmartDialog.showToast("登录成功！");
    } else {
      SmartDialog.showToast("WebDAV账号密码验证失败，请重新输入！");
    }
  }

  // WebDAV登出
  @override
  Future<void> onLogout() async {
    var result = await Utils.showAlertDialog("确定要登出WebDAV账号？", title: "退出登录");
    if (result) {
      // 清除本地账号数据
      await LocalStorageService.instance.setValue(
        LocalStorageService.kWebDAVUri,
        "",
      );
      await LocalStorageService.instance.setValue(
        LocalStorageService.kWebDAVUser,
        "",
      );
      await LocalStorageService.instance.setValue(
        LocalStorageService.kWebDAVPassword,
        "",
      );
      notLogin.value = true;
    }
  }

  Future<void> doWebDAVUpload() async {
    if (_busy) return;
    _busy = true;
    SmartDialog.showLoading(msg: "正在上传到云端");
    try {
      await davClient.backup(Uint8List.fromList(await createBackup()));
      final time = DateTime.now();
      await LocalStorageService.instance.setValue(
        LocalStorageService.kWebDAVLastUploadTime,
        time.millisecondsSinceEpoch,
      );
      lastUploadTime.value = Utils.parseTime(time);
      SmartDialog.showToast("上传成功（备份不包含账号和 WebDAV 凭据）");
    } catch (_, stack) {
      Log.e("WebDAV 上传失败", stack);
      SmartDialog.showToast("上传失败，请检查连接后重试");
    } finally {
      _busy = false;
      await SmartDialog.dismiss();
    }
  }

  /// Construct exactly the allowed documents in memory; stale temporary files
  /// and credentials can never be pulled into a directory-wide ZIP operation.
  Future<List<int>> createBackup() async {
    final archive = Archive();
    void add(String name, Object data) {
      final bytes = utf8.encode(jsonEncode({'version': 2, 'data': data}));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    final snapshot = await DBService.instance.exportSnapshot();
    add(_userFollowJsonName, snapshot['follows']!);
    add(_userTagsJsonName, snapshot['tags']!);
    add(
      _userHistoriesJsonName,
      DBService.instance.getHistores().map((item) => item.toJson()).toList(),
    );
    add(
      _userBlockedWordJsonName,
      AppSettingsController.instance.shieldList.toList(),
    );
    add(_userSettingsJsonName, LocalStorageService.instance.exportSettings());
    return ZipEncoder().encode(archive);
  }

  Future<void> doWebDAVRecovery() async {
    if (_busy) return;
    _busy = true;
    SmartDialog.showLoading(msg: "正在恢复到本地");
    try {
      final data = await davClient.recovery();
      if (data.length > 32 * 1024 * 1024) {
        throw const FormatException('Backup too large');
      }
      final archive = await Isolate.run<Archive>(
        () => ZipDecoder().decodeBytes(data, verify: true),
      );
      final result = await restoreArchive(archive);
      if (result.failed.isNotEmpty) {
        SmartDialog.showToast(
          '${result.succeeded.isEmpty ? "恢复失败" : "部分恢复成功"}：'
          '${result.failed.join("、")}，请重试',
        );
      } else if (result.succeeded.isEmpty) {
        SmartDialog.showToast('备份中没有已选择的可恢复数据');
      } else {
        final time = DateTime.now();
        await LocalStorageService.instance.setValue(
          LocalStorageService.kWebDAVLastRecoverTime,
          time.millisecondsSinceEpoch,
        );
        lastRecoverTime.value = Utils.parseTime(time);
        SmartDialog.showToast('同步完成');
      }
    } catch (_, stack) {
      Log.e('WebDAV 恢复失败', stack);
      SmartDialog.showToast('恢复失败，请检查备份和连接后重试');
    } finally {
      _busy = false;
      await SmartDialog.dismiss();
    }
  }

  Future<WebDavRestoreResult> restoreArchive(Archive archive) async {
    final selected = <String>{
      if (isSyncFollows.value) _userFollowJsonName,
      if (isSyncFollows.value) _userTagsJsonName,
      if (isSyncHistories.value) _userHistoriesJsonName,
      if (isSyncBlockWord.value) _userBlockedWordJsonName,
      if (isSyncBilibiliAccount.value) _userBilibiliAccountJsonName,
      _userSettingsJsonName,
    };
    final documents = <String, dynamic>{};
    var totalSize = 0;
    for (final file in archive) {
      if (!file.isFile || !selected.contains(file.name)) continue;
      totalSize += file.size;
      if (totalSize > 32 * 1024 * 1024 || documents.containsKey(file.name)) {
        throw const FormatException('Invalid backup contents');
      }
      final document = jsonDecode(utf8.decode(file.content as List<int>));
      if (document is! Map ||
          (document['version'] != null && document['version'] != 2) ||
          !document.containsKey('data')) {
        throw const FormatException('Unsupported backup document');
      }
      documents[file.name] = document['data'];
    }
    // Validate every selected document before the first persistent mutation.
    final follows = documents[_userFollowJsonName] as List?;
    final tags = documents[_userTagsJsonName] as List?;
    DBService.validateSnapshot(follows: follows, tags: tags);
    final histories = documents.containsKey(_userHistoriesJsonName)
        ? DBService.parseHistories(
            documents[_userHistoriesJsonName] as List,
          ).values.toList()
        : null;
    final words = documents.containsKey(_userBlockedWordJsonName)
        ? validateShieldRules(documents[_userBlockedWordJsonName] as List)
        : null;
    final settings = documents.containsKey(_userSettingsJsonName)
        ? LocalStorageService.validateSettings(
            documents[_userSettingsJsonName] as Map,
          )
        : null;
    final account = documents[_userBilibiliAccountJsonName] as Map?;
    final cookie = account == null ? null : account['cookie'] as String;
    final result = WebDavRestoreResult();
    Future<void> restore(String name, Future<void> Function() write) async {
      try {
        await write();
        result.succeeded.add(name);
      } catch (_, stack) {
        result.failed.add(name);
        Log.e('恢复$name失败', stack);
      }
    }

    if (follows != null || tags != null) {
      await restore('关注和标签', () async {
        await DBService.instance.importSnapshot(
          follows: follows,
          tags: tags,
          replace: true,
        );
        EventBus.instance.emit(Constant.kUpdateFollow, 0);
      });
    }
    if (histories != null) {
      await restore('观看历史', () async {
        await DBService.instance.importHistories(
          histories.map((item) => item.toJson()),
          replace: false,
        );
        EventBus.instance.emit(Constant.kUpdateHistory, 0);
      });
    }
    if (words != null) {
      await restore('屏蔽词', () async {
        await AppSettingsController.instance.importShieldRules(
          words,
          replace: false,
        );
      });
    }
    if (settings != null) {
      await restore('设置', () async {
        await LocalStorageService.instance.restoreSettings(settings);
        AppSettingsController.instance.reloadSettings();
      });
    }
    if (cookie != null) {
      await restore('旧备份账号', () async {
        await BiliBiliAccountService.instance.setCookie(cookie);
        await BiliBiliAccountService.instance.loadUserInfo();
      });
    }
    return result;
  }

  // ui控制--密码可见控制
  void changePasswordVisible() {
    passwordVisible.value = !passwordVisible.value;
  }

  void changeIsSyncFollows() {
    isSyncFollows.value = !isSyncFollows.value;
  }

  void changeIsSyncHistories() {
    isSyncHistories.value = !isSyncHistories.value;
  }

  void changeIsSyncBlockWord() {
    isSyncBlockWord.value = !isSyncBlockWord.value;
  }

  void changeIsSyncBilibiliAccount() {
    isSyncBilibiliAccount.value = !isSyncBilibiliAccount.value;
  }
}

class WebDavRestoreResult {
  final List<String> succeeded = [];
  final List<String> failed = [];
}
