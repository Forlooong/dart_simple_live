import 'dart:ffi';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class AppUpdateService {
  static const _channel = MethodChannel('simple_live/update');
  static bool _busy = false;

  static Future<void> check({bool automatic = false}) async {
    if (_busy) return;
    final storage = LocalStorageService.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (automatic && now - storage.getValue<int>('UpdateLastCheck', 0) <
        const Duration(days: 1).inMilliseconds) return;
    // Defer startup prompts while another dialog or a room is active.
    if (automatic && (Get.isDialogOpen == true ||
        Get.currentRoute.contains('/room/'))) return;
    _busy = true;
    var userRequestedInstall = false;
    try {
      if (automatic) await storage.setValue('UpdateLastCheck', now);
      final info = await PackageInfo.fromPlatform();
      final current = int.parse(info.buildNumber);
      final update = await AppUpdateClient().check('main');
      if (update == null) {
        if (!automatic) await _message('当前尚未发布更新');
        return;
      }
      Map<String, dynamic> identity = {};
      String arch;
      if (Platform.isAndroid) {
        identity = Map<String, dynamic>.from(
            (await _channel.invokeMapMethod<String, dynamic>('identity'))!);
        arch = identity['arch'] as String;
      } else {
        final abi = Abi.current().toString().toLowerCase();
        arch = abi.contains('arm64') ? 'arm64' :
            abi.contains('x64') ? 'x64' : 'unsupported';
      }
      final platform = Platform.operatingSystem;
      final candidates = update.packages.where((p) =>
          p.platform == platform && (p.arch == arch || p.arch == 'universal') &&
          p.build > current).toList();
      if (candidates.isEmpty) {
        if (!automatic) await _message(update.packages.any((p) =>
            p.platform == platform && (p.arch == arch || p.arch == 'universal'))
            ? '已是最新版本' : '没有适合当前平台或架构的更新包');
        return;
      }
      final package = update.select(platform: platform, arch: arch,
          installedBuild: current, packageId: info.packageName,
          certificate: identity['certificate'] as String? ?? '',
          sdk: identity['sdk'] as int? ?? 0);
      if (package == null) {
        if (!automatic) await _message('发现新版，但没有与当前架构、系统或签名兼容的安装包。请查看发布说明。');
        return;
      }
      if (automatic && storage.getValue<int>('UpdateIgnoredBuild', 0) == package.build) return;
      final action = await Get.dialog<String>(AlertDialog(
        title: Text('发现新版本 v' + update.version),
        content: SingleChildScrollView(child: Text(update.notes +
            (Platform.isIOS ? '\n\n当前 IPA 未签名，请通过已授权的分发渠道安装。' :
            '\n\n安装包：' + (package.size / 1048576).toStringAsFixed(1) + ' MB'))),
        actions: [
          TextButton(onPressed: () => Get.back(result: 'ignore'), child: const Text('忽略此版本')),
          TextButton(onPressed: () => Get.back(), child: const Text('稍后')),
          TextButton(autofocus: true, onPressed: () => Get.back(result: 'install'),
              child: Text(Platform.isIOS ? '查看分发页' : '立即更新')),
        ],
      ));
      if (action == 'ignore') {
        await storage.setValue('UpdateIgnoredBuild', package.build);
      } else if (action == 'install') {
        userRequestedInstall = true;
        if (Platform.isIOS) {
          await launchUrl(Uri.parse(updateReleasePage), mode: LaunchMode.externalApplication);
        } else {
          await _download(package, info.packageName);
        }
      }
    } catch (_) {
      if (!automatic || userRequestedInstall) await _message('检查或安装更新失败，请检查网络后重试，或前往本分支发布页。');
    } finally {
      _busy = false;
    }
  }

  static Future<void> _download(UpdatePackage package, String id) async {
    final cancel = CancelToken();
    final progress = ValueNotifier<double>(0);
    final dialog = Get.dialog<void>(PopScope(canPop: false, child: AlertDialog(
      title: const Text('正在下载更新'),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, value, __) => LinearProgressIndicator(value: value)),
      actions: [TextButton(autofocus: true,
          onPressed: () => cancel.cancel('用户取消'), child: const Text('取消'))],
    )), barrierDismissible: false);
    File? file;
    Object? failure;
    try {
      file = await AppUpdateClient().download(package,
          Directory(Directory.systemTemp.path + '/simple-live-updates-' + id),
          cancel: cancel, progress: (received, total) => progress.value = received / total);
    } catch (error) {
      failure = error;
    } finally {
      if (Get.isDialogOpen == true) Get.back<void>();
      await dialog;
      progress.dispose();
    }
    if (cancel.isCancelled) return;
    if (failure != null || file == null) {
      await _message('下载或完整性校验失败，请重试');
      return;
    }
    if (Platform.isAndroid) {
      final result = await _channel.invokeMethod<String>('install', {
        'path': file.path, 'build': package.build,
        'certificate': package.certificate,
      });
      if (result == 'permission') {
        await _message('请允许此应用安装更新，授权后再次点击检查更新。');
      }
    } else {
      final command = Platform.isWindows ? file.path :
          Platform.isMacOS ? 'open' : 'xdg-open';
      final args = Platform.isWindows ? <String>[] : [file.path];
      if (Platform.isWindows) {
        await Process.start(command, args, mode: ProcessStartMode.detached);
      } else {
        final opened = await Process.run(command, args);
        if (opened.exitCode != 0) {
          await _message('系统未能打开安装包，请安装相应的文件处理程序，或前往发布页手动下载。');
          return;
        }
      }
      await _message(Platform.isWindows
          ? '安装器已打开，请按提示关闭应用并完成覆盖安装。'
          : '安装包已打开，请通过系统完成更新。');
    }
  }

  static Future<void> _message(String text) async {
    await Get.dialog<void>(AlertDialog(content: Text(text), actions: [
      TextButton(autofocus: true, onPressed: () => Get.back(), child: const Text('确定')),
      TextButton(onPressed: () {
        launchUrl(Uri.parse(updateReleasePage), mode: LaunchMode.externalApplication);
      }, child: const Text('发布页')),
    ]));
  }
}

