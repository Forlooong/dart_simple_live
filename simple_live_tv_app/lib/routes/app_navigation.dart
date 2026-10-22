import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/category/category_controller.dart';
import 'package:simple_live_tv_app/routes/route_path.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';

/// APP页面跳转封装
/// * 需要参数的页面都应使用此类
/// * 如不需要参数，可以使用Get.toNamed
class AppNavigator {
  static int _liveRoomNavigationRequest = 0;

  /// 跳转至直播间
  static void toLiveRoomDetail({
    required Site site,
    required String roomId,
  }) async {
    final request = ++_liveRoomNavigationRequest;
    if (site.id == Constant.kBiliBili &&
        !BiliBiliAccountService.instance.logined.value &&
        AppSettingsController.instance.bilibiliLoginTip.value) {
      await toBiliBiliLogin();
      if (!BiliBiliAccountService.instance.logined.value) {
        SmartDialog.showToast("未完成登录");
        return;
      }
    }

    if (!await waitForPlayerCleanup(PlayerController.pendingCleanup)) return;
    if (request != _liveRoomNavigationRequest) return;
    Get.toNamed(
      RoutePath.kLiveRoomDetail,
      arguments: site,
      parameters: {"roomId": roomId},
    );
  }

  /// Cancel only the navigation; never race native cleanup with another player.
  static Future<bool>? _cleanupWait;

  static Future<bool> waitForPlayerCleanup(Future<void> cleanup) {
    return _cleanupWait ??= _waitForPlayerCleanup(cleanup).whenComplete(() {
      _cleanupWait = null;
    });
  }

  static Future<bool> _waitForPlayerCleanup(Future<void> cleanup) async {
    final ready = Completer<bool>();
    final timer = Timer(
      const Duration(seconds: 2),
      () => ready.complete(false),
    );
    cleanup.then((_) {
      if (!ready.isCompleted) ready.complete(true);
    });
    final completed = await ready.future;
    timer.cancel();
    if (completed) return true;
    final context = Get.context;
    if (context == null || !context.mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => FutureBuilder<void>(
            future: cleanup,
            builder: (context, state) {
              if (state.connectionState == ConnectionState.done) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (dialogContext.mounted &&
                      ModalRoute.of(dialogContext)?.isCurrent == true) {
                    Navigator.of(dialogContext).pop(true);
                  }
                });
              }
              return AlertDialog(
                title: const Text('正在关闭上一个播放器'),
                content: const Text('播放器尚未完成资源释放。可以取消本次打开；若长时间没有完成，请重启应用后重试。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('取消打开'),
                  ),
                ],
              );
            },
          ),
        ) ??
        false;
  }

  /// 跳转至哔哩哔哩登录
  static Future toBiliBiliLogin() async {
    await Get.toNamed(RoutePath.kBiliBiliQRLogin);
  }

  /// 跳转至分类详情
  static void toCategoryDetail({
    required Site site,
    required LiveSubCategoryExt category,
  }) {
    Get.toNamed(RoutePath.kCategoryDetail, arguments: [site, category]);
  }
}
