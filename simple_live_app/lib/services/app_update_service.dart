import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateService {
  static const _channel = MethodChannel('simple_live/update');
  static bool _busy = false;

  static bool _mayPrompt() =>
      Get.isDialogOpen != true && !Get.currentRoute.contains('/room/');

  static Future<void> check({bool automatic = false}) async {
    if (_busy) {
      if (!automatic) Get.rawSnackbar(message: '正在检查或处理更新');
      return;
    }
    final storage = LocalStorageService.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (automatic &&
        (!_mayPrompt() ||
            now - storage.getValue<int>('UpdateLastCheck', 0) <
                const Duration(days: 1).inMilliseconds)) {
      return;
    }
    _busy = true;
    final client = AppUpdateClient();
    var releaseUri = updateReleaseUri(null);
    var installing = false;
    try {
      final info = await PackageInfo.fromPlatform();
      final update = await client.check('main');
      await storage.setValue('UpdateLastCheck', now);
      if (update == null) {
        if (!automatic) await _message('当前尚未发布更新', releaseUri);
        return;
      }
      releaseUri = update.releaseUri;
      final platform = Platform.operatingSystem;
      final current = installedUpdateBuild(
        info.buildNumber,
        platform: platform,
      );
      final arch = switch (Abi.current()) {
        Abi.androidArm => 'arm32',
        Abi.androidArm64 ||
        Abi.iosArm64 ||
        Abi.macosArm64 ||
        Abi.linuxArm64 ||
        Abi.windowsArm64 => 'arm64',
        Abi.androidX64 ||
        Abi.macosX64 ||
        Abi.linuxX64 ||
        Abi.windowsX64 => 'x64',
        _ => 'unsupported',
      };
      final matches = update.packages.where(
        (p) =>
            p.platform == platform && (p.arch == arch || p.arch == 'universal'),
      );
      UpdatePackage? package;
      String? cachePath;
      String status;
      if (matches.isEmpty) {
        status = '此发布没有适用于当前平台或架构的安装包';
      } else if (current == null) {
        status = '无法识别本机版本号，请通过发布页选择安装包';
      } else if (!matches.any((p) => p.build > current)) {
        status = '当前版本无需更新';
      } else {
        Map<String, dynamic> identity = const {};
        if (Platform.isAndroid) {
          try {
            identity =
                await _channel.invokeMapMethod<String, dynamic>('identity') ??
                const {};
          } on PlatformException {
            // Details remain available if Android cannot read the signature.
          } on MissingPluginException {
            // Older or unsupported hosts can still open the release page.
          }
          cachePath = identity['cachePath'] as String?;
        }
        package = update.select(
          platform: platform,
          arch: arch,
          installedBuild: current,
          packageId: info.packageName,
          certificate: identity['certificate'] as String? ?? '',
          sdk: identity['sdk'] as int? ?? 0,
        );
        status = switch (package) {
          null
              when Platform.isAndroid && !identity.containsKey('certificate') =>
            '无法读取本机安装签名，请查看发布页',
          null => '有新版，安装包与本机签名或系统版本不兼容',
          _ when Platform.isIOS => '发现新版，IPA 需要签名后安装',
          _ => '可以更新',
        };
      }

      if (automatic &&
          (package == null ||
              !_mayPrompt() ||
              storage.getValue<int>('UpdateIgnoredBuild', 0) ==
                  package.build)) {
        return;
      }
      final selected = package;
      final action = await Get.dialog<String>(
        AlertDialog(
          title: const Text('更新详情'),
          scrollable: true,
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              [
                '当前版本  v${info.version}（${info.buildNumber}）',
                '发布版本  v${update.version}',
                if (update.publishedAt case final published?)
                  '发布时间  ${published.toLocal().toString().substring(0, 16)}',
                status,
                if (selected != null)
                  '安装包  ${selected.arch} · ${(selected.size / 1048576).toStringAsFixed(1)} MB',
                '',
                update.notes.trim().isEmpty ? '此版本暂无更新说明' : update.notes,
              ].join('\n'),
            ),
          ),
          actions: [
            if (selected != null)
              TextButton(
                onPressed: () => Get.back(result: 'ignore'),
                child: const Text('忽略此版本'),
              ),
            TextButton(
              onPressed: () => Get.back(result: 'release'),
              child: const Text('发布页'),
            ),
            TextButton(
              autofocus: selected == null,
              onPressed: () => Get.back(),
              child: Text(selected == null ? '关闭' : '稍后'),
            ),
            if (selected != null && !Platform.isIOS)
              FilledButton(
                autofocus: true,
                onPressed: () => Get.back(result: 'install'),
                child: const Text('下载并安装'),
              ),
          ],
        ),
      );
      if (action == 'release') {
        await _openRelease(releaseUri);
      } else if (action == 'ignore' && selected != null) {
        await storage.setValue('UpdateIgnoredBuild', selected.build);
      } else if (action == 'install' && selected != null) {
        installing = true;
        final root = cachePath ?? Directory.systemTemp.path;
        await _download(
          client,
          selected,
          Directory('$root/simple-live-updates-${info.packageName}'),
          releaseUri,
        );
      }
    } catch (error) {
      if (!automatic || installing) {
        await _message(
          _errorText(error, installing ? '安装更新' : '检查更新'),
          releaseUri,
        );
      }
    } finally {
      client.dio.close(force: true);
      _busy = false;
    }
  }

  static String _errorText(Object error, String action) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 429) {
        return '$action暂时受 GitHub 限制，可稍后重试或打开发布页。';
      }
      if (code != null) return '$action失败，GitHub 返回 HTTP $code。';
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => '$action超时，暂时无法访问 GitHub 或其下载服务。',
        DioExceptionType.badCertificate => '$action失败，无法验证 GitHub 的网络证书。',
        _ => '$action失败，暂时无法连接 GitHub 或其下载服务。',
      };
    }
    if (error is FormatException) {
      return action == '检查更新'
          ? '更新清单格式或完整性校验失败。'
          : '安装包大小或 SHA-256 校验失败，请重新下载。';
    }
    if (error is FileSystemException) {
      return action == '检查更新' ? '读取本机更新设置失败。' : '无法保存或打开安装包，请检查存储空间和系统权限。';
    }
    return '$action失败，可从发布页选择适用的安装包。';
  }

  static Future<void> _download(
    AppUpdateClient client,
    UpdatePackage package,
    Directory directory,
    Uri releaseUri,
  ) async {
    final cancel = CancelToken();
    final progress = ValueNotifier<double>(0);
    final dialog = Get.dialog<void>(
      PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在下载更新'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, value, __) => LinearProgressIndicator(
              value: value,
              semanticsLabel: '安装包下载进度',
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => cancel.cancel(),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
      barrierDismissible: false,
    );
    File? file;
    Object? failure;
    try {
      file = await client.download(
        package,
        directory,
        cancel: cancel,
        progress: (received, total) => progress.value = received / total,
      );
    } catch (error) {
      failure = error;
    } finally {
      if (Get.isDialogOpen == true) Get.back<void>();
      await dialog;
      progress.dispose();
    }
    if (failure is DioException && CancelToken.isCancel(failure)) return;
    if (failure != null) {
      await _message(_errorText(failure, '下载安装包'), releaseUri);
      return;
    }
    if (file == null || cancel.isCancelled) return;
    if (Platform.isAndroid) {
      final result = await _channel.invokeMethod<String>('install', {
        'path': file.path,
        'build': package.build,
        'certificate': package.certificate,
      });
      if (result == 'permission') {
        await _message('请允许此应用安装更新，授权后再次打开「软件更新」。', releaseUri);
      }
    } else if (Platform.isWindows) {
      await Process.start(file.path, [], mode: ProcessStartMode.detached);
      await _message('安装器已打开，请按提示关闭应用并完成覆盖安装。', releaseUri);
    } else {
      final opened = await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [
        file.path,
      ]);
      await _message(
        opened.exitCode == 0 ? '安装包已打开，请通过系统完成更新。' : '系统无法打开安装包，可从发布页下载并手动安装。',
        releaseUri,
      );
    }
  }

  static Future<void> _openRelease(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await _message('系统无法打开浏览器，请通过 GitHub 查看此版本。', uri, showRelease: false);
    }
  }

  static Future<void> _message(
    String text,
    Uri uri, {
    bool showRelease = true,
  }) async {
    final action = await Get.dialog<String>(
      AlertDialog(
        content: Text(text),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Get.back(),
            child: const Text('确定'),
          ),
          if (showRelease)
            TextButton(
              onPressed: () => Get.back(result: 'release'),
              child: const Text('发布页'),
            ),
        ],
      ),
    );
    if (action == 'release') await _openRelease(uri);
  }
}
