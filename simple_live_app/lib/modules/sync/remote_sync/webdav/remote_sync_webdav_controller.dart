import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

import 'webdav_restore.dart';

export 'webdav_restore.dart';

class RemoteSyncWebDAVController extends BaseController {
  // ui
  var passwordVisible = true.obs;
  bool _busy = false;
  int _sessionGeneration = 0;

  late DAVClient davClient;
  var user = "--".obs;
  var lastRecoverTime = "--".obs;
  var lastUploadTime = "--".obs;

  @override
  void onInit() {
    doWebDAVInit();
    super.onInit();
  }

  // webDAV 逻辑
  // 初始化webDAV
  void doWebDAVInit() {
    final session = LocalStorageService.instance.webDavSession;
    if (session == null) {
      notLogin.value = true;
    } else {
      final target = Uri.tryParse(session.uri);
      final confirmed = session.confirmed;
      if (target == null ||
          !_validTarget(target) ||
          ((target.scheme == 'http' || confirmed.isNotEmpty) &&
              confirmed != target.toString())) {
        notLogin.value = true;
        return;
      }
      user.value = session.user;
      davClient = DAVClient(session.uri, session.user, session.password);
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
    final generation = _sessionGeneration;
    final connected = await davClient.pingCompleter.future;
    if (!isClosed && generation == _sessionGeneration) {
      notLogin.value = !connected;
    }
  }

  bool _validTarget(Uri uri) =>
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;

  // WebDAV登录
  Future<void> doWebDAVLogin(
    String webDAVUri,
    String webDAVUser,
    String webDAVPassword,
  ) async {
    if (_busy) return;
    _busy = true;
    try {
      final uri = Uri.tryParse(webDAVUri.trim());
      if (uri == null || !_validTarget(uri)) {
        SmartDialog.showToast('请输入有效的 WebDAV 地址');
        return;
      }
      final storage = LocalStorageService.instance;
      final target = uri.toString();
      if (storage.webDavSession?.uri != target || uri.scheme == 'http') {
        final message = uri.scheme == 'http'
            ? '将通过未加密的 HTTP 向 ' + uri.origin + ' 发送 WebDAV 登录凭据。'
            : '将向 ' + uri.origin + ' 发送 WebDAV 登录凭据。';
        if (!await Utils.showAlertDialog(message, title: '确认 WebDAV 服务'))
          return;
      }
      final candidate = DAVClient(target, webDAVUser, webDAVPassword);
      if (!await candidate.pingCompleter.future) {
        SmartDialog.showToast('WebDAV 账号验证失败，请重试');
        return;
      }
      if (isClosed) return;
      await storage.saveWebDavSession(
        uri: target,
        user: webDAVUser,
        password: webDAVPassword,
      );
      ++_sessionGeneration;
      davClient = candidate;
      user.value = webDAVUser;
      notLogin.value = false;
      if (!isClosed) {
        Get.back();
        SmartDialog.showToast('登录成功！');
      }
    } catch (_, stack) {
      Log.e('WebDAV 会话保存失败', stack);
      SmartDialog.showToast('WebDAV 会话保存失败');
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> onLogout() async {
    if (_busy) return;
    _busy = true;
    try {
      if (!await Utils.showAlertDialog('确定要登出 WebDAV 账号？', title: '退出登录')) {
        return;
      }
      await LocalStorageService.instance.clearWebDavSession();
      ++_sessionGeneration;
      notLogin.value = true;
      user.value = '--';
    } catch (_, stack) {
      Log.e('WebDAV 会话清除失败', stack);
      SmartDialog.showToast('退出登录失败');
    } finally {
      _busy = false;
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
    add(WebDavBackup.followsFile, snapshot['follows']!);
    add(WebDavBackup.tagsFile, snapshot['tags']!);
    add(
      WebDavBackup.historyFile,
      DBService.instance.getHistores().map((item) => item.toJson()).toList(),
    );
    add(
      WebDavBackup.shieldFile,
      AppSettingsController.instance.shieldList.toList(),
    );
    add(
      WebDavBackup.settingsFile,
      LocalStorageService.instance.exportSettings(),
    );
    return ZipEncoder().encode(archive);
  }

  Future<WebDavBackup> _downloadBackup({bool accountOnly = false}) async {
    final data = await davClient.recovery();
    if (data.length > WebDavBackup.maxSize) {
      throw const FormatException('备份文件过大');
    }
    return Isolate.run(
      () => WebDavBackup.decode(data, accountOnly: accountOnly),
    );
  }

  Future<void> doWebDAVRecovery() async {
    if (_busy) return;
    _busy = true;
    try {
      SmartDialog.showLoading(msg: '正在读取备份');
      final preview = await (() async {
        try {
          return await WebDavRestore().preview(await _downloadBackup());
        } finally {
          await SmartDialog.dismiss();
        }
      })();
      final changes = await Get.dialog<List<RestoreChange>>(
        _WebDavPreviewDialog(preview: preview),
      );
      if (changes == null) return;
      final result = await WebDavRestore().apply(changes);
      if (result.failed.isEmpty &&
          result.skipped.isEmpty &&
          result.succeeded.isNotEmpty) {
        final time = DateTime.now();
        await LocalStorageService.instance.setValue(
          LocalStorageService.kWebDAVLastRecoverTime,
          time.millisecondsSinceEpoch,
        );
        lastRecoverTime.value = Utils.parseTime(time);
      }
      await _showResult('恢复结果', result);
    } catch (_, stack) {
      Log.e('WebDAV 恢复失败', stack);
      SmartDialog.showToast('恢复失败，请检查备份和连接后重试');
    } finally {
      _busy = false;
    }
  }

  Future<WebDavRestoreResult> restoreArchive(Archive archive) async {
    final restore = WebDavRestore();
    final preview = await restore.preview(WebDavBackup.read(archive));
    return restore.apply([
      for (final group in RestoreGroup.values)
        if (preview.backup.has(group)) preview.change(group, RestoreMode.merge),
    ]);
  }

  Future<void> rollback() async {
    if (_busy) return;
    _busy = true;
    try {
      final restore = WebDavRestore();
      if (!await restore.hasRollback()) {
        SmartDialog.showToast('没有可用的本地回滚点');
        return;
      }
      if (await Utils.showAlertDialog(
        '还原最近一次恢复前的数据。已在恢复后修改的类别会保留。',
        title: '回滚 WebDAV 恢复',
      )) {
        await _showResult('回滚结果', await restore.rollback());
      }
    } catch (_, stack) {
      Log.e('WebDAV 回滚失败', stack);
      SmartDialog.showToast('回滚失败，请稍后重试');
    } finally {
      _busy = false;
    }
  }

  Future<void> importLegacyAccount() async {
    if (_busy) return;
    _busy = true;
    try {
      if (!await Utils.showAlertDialog(
        '将验证旧备份内的哔哩哔哩会话。会话有效时会替换当前账号，账号不能通过数据回滚还原。',
        title: '导入旧备份账号',
      ))
        return;
      final cookie = (await _downloadBackup(accountOnly: true)).legacyCookie;
      if (cookie == null) {
        SmartDialog.showToast('备份中没有可导入的账号');
        return;
      }
      final imported = await BiliBiliAccountService.instance
          .importVerifiedCookie(cookie);
      SmartDialog.showToast(imported ? '已导入哔哩哔哩账号' : '会话验证失败，已保留当前账号');
    } catch (_, stack) {
      Log.e('旧备份账号导入失败', stack);
      SmartDialog.showToast('账号导入失败');
    } finally {
      _busy = false;
    }
  }

  Future<void> _showResult(String title, WebDavRestoreResult result) =>
      Get.dialog<void>(
        AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Text(
              [
                for (final name in result.succeeded) '$name · 已完成',
                for (final name in result.unchanged) '$name · 无需更改',
                for (final name in result.skipped) '$name · 本地已有新改动，已跳过',
                for (final name in result.failed) '$name · 失败',
                if (result.succeeded.isEmpty &&
                    result.unchanged.isEmpty &&
                    result.skipped.isEmpty &&
                    result.failed.isEmpty)
                  '没有选中的可恢复数据',
              ].join('\n'),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Get.back(), child: const Text('关闭')),
          ],
        ),
      );

  void changePasswordVisible() => passwordVisible.toggle();
}

class _WebDavPreviewDialog extends StatefulWidget {
  const _WebDavPreviewDialog({required this.preview});
  final WebDavRestorePreview preview;

  @override
  State<_WebDavPreviewDialog> createState() => _WebDavPreviewDialogState();
}

class _WebDavPreviewDialogState extends State<_WebDavPreviewDialog> {
  final modes = {
    for (final group in RestoreGroup.values) group: RestoreMode.merge,
  };
  bool restoreBells = false;

  @override
  Widget build(BuildContext context) {
    final changes = <RestoreChange>[];
    final rows = <Widget>[];
    var invalid = false;
    for (final group in RestoreGroup.values) {
      final present = widget.preview.backup.has(group);
      final mode = modes[group]!;
      final details = <String>[];
      if (!present) {
        details.add('备份中缺少此类别');
      } else if (mode != RestoreMode.skip) {
        try {
          final change = widget.preview.change(
            group,
            mode,
            restoreBells: restoreBells,
          );
          changes.add(change);
          for (final entry in change.differences.entries) {
            details.add('${entry.key} · ${entry.value.label}');
          }
          if (mode == RestoreMode.replace) details.add('将移除预览所列的本机数据');
        } on FormatException catch (error) {
          invalid = true;
          details.add(error.message);
        }
      } else {
        details.add('保留本机数据');
      }
      rows.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(group.label),
          subtitle: Text(details.join('\n')),
          trailing: present
              ? DropdownButton<RestoreMode>(
                  value: mode,
                  onChanged: (value) => setState(() => modes[group] = value!),
                  items: [
                    for (final mode in RestoreMode.values)
                      DropdownMenuItem(value: mode, child: Text(mode.label)),
                  ],
                )
              : null,
        ),
      );
    }
    return AlertDialog(
      title: const Text('WebDAV 恢复预览'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...rows,
              if (widget.preview.backup.has(RestoreGroup.follows))
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('应用备份中的开播提醒选择'),
                  value: restoreBells,
                  onChanged: modes[RestoreGroup.follows] == RestoreMode.skip
                      ? null
                      : (value) => setState(() => restoreBells = value!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Get.back(), child: const Text('取消')),
        FilledButton(
          onPressed: invalid || changes.isEmpty
              ? null
              : () => Get.back(result: changes),
          child: const Text('确认恢复'),
        ),
      ],
    );
  }
}
