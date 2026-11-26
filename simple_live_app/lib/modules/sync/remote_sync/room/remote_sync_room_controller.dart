import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/signalr_service.dart';

class RemoteSyncRoomController extends BaseController {
  final String roomId;
  final SignalRService signalR = SignalRService();
  RemoteSyncRoomController(this.roomId) {
    if (roomId.isNotEmpty) {
      currentRoomId.value = roomId;
    }
  }
  StreamSubscription? _roomDestroyedSubscription;
  StreamSubscription? _roomUserUpdatedSubscription;
  StreamSubscription? _onFavoriteSubscription;
  StreamSubscription? _onHistorySubscription;
  StreamSubscription? _onShieldWordSubscription;
  StreamSubscription? _onBiliAccountSubscription;
  var currentRoomId = "--".obs;
  RxList<RoomUser> roomUsers = <RoomUser>[].obs;

  Timer? _timer;
  var countDown = 600.obs;

  @override
  void onInit() {
    connect();
    super.onInit();
  }

  void connect() async {
    listenSignalR();
    await signalR.connect();
    if (signalR.state == SignalRConnectionState.connected) {
      if (roomId.isEmpty) {
        createRoom();
      } else {
        joinRoom(roomId);
      }
    }
  }

  void createRoom() async {
    try {
      var resp = await signalR.createRoom();
      if (resp.isSuccess) {
        currentRoomId.value = resp.data!;
        _startTimer();
      } else {
        SmartDialog.showToast(resp.message);
        Get.back();
      }
    } catch (e) {
      SmartDialog.showToast("创建房间失败");
      Get.back();
    }
  }

  void _startTimer() {
    // 倒计时5分钟，自动关闭页面
    countDown.value = 600;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      countDown--;
      if (countDown <= 0) {
        timer.cancel();
        Get.back();
      }
    });
  }

  void joinRoom(String roomId) async {
    try {
      var resp = await signalR.joinRoom(roomId);
      if (!resp.isSuccess) {
        SmartDialog.showToast(resp.message);
        Get.back();
      }
    } catch (e) {
      SmartDialog.showToast("加入房间失败");
      Get.back();
    }
  }

  void listenSignalR() {
    _roomDestroyedSubscription = signalR.onRoomDestroyedStream.listen((roomId) {
      SmartDialog.showToast("房间已被销毁");
      Get.back();
    });
    _roomUserUpdatedSubscription = signalR.onRoomUserUpdatedStream.listen((
      roomUsers,
    ) {
      this.roomUsers.assignAll(roomUsers);
    });
    _onFavoriteSubscription = signalR.onFavoriteStream.listen((data) {
      onReceiveFavorite(data.$1, data.$2);
    });
    _onHistorySubscription = signalR.onHistoryStream.listen((data) {
      onReceiveHistory(data.$1, data.$2);
    });
    _onShieldWordSubscription = signalR.onShieldWordStream.listen((data) {
      onReceiveShieldWord(data.$1, data.$2);
    });
    _onBiliAccountSubscription = signalR.onBiliAccountStream.listen((data) {
      onReceiveBiliAccount(data.$1, data.$2);
    });
  }

  void onReceiveFavorite(bool overlay, String data) async {
    try {
      final jsonBody = json.decode(data) as List;
      await DBService.instance.importFollows(jsonBody, replace: overlay);
      SmartDialog.showToast('已同步关注用户列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      SmartDialog.showToast("已同步关注列表");
    } catch (e) {
      SmartDialog.showToast("同步失败，请重试");
      Log.w("远程房间同步失败");
    }
  }

  void onReceiveHistory(bool overlay, String data) async {
    try {
      final jsonBody = json.decode(data) as List;
      await DBService.instance.importHistories(jsonBody, replace: overlay);
      SmartDialog.showToast('已同步历史记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
    } catch (e) {
      SmartDialog.showToast("同步失败，请重试");
      Log.w("远程房间同步失败");
    }
  }

  void onReceiveShieldWord(bool overlay, String data) async {
    try {
      final jsonBody = json.decode(data) as List;
      await AppSettingsController.instance.importShieldRules(
        jsonBody,
        replace: overlay,
      );
      SmartDialog.showToast('已同步屏蔽词');
    } catch (e) {
      SmartDialog.showToast("同步失败，请重试");
      Log.w("远程房间同步失败");
    }
  }

  void onReceiveBiliAccount(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      var cookie = jsonBody['cookie'];
      if (cookie is! String ||
          cookie.isEmpty ||
          cookie.length > 65536 ||
          !await Utils.showAlertDialog(
            '同步房间送来了哔哩哔哩会话。继续会替换当前账号。',
            title: '接收哔哩哔哩账号',
          ))
        return;
      if (!await BiliBiliAccountService.instance.importVerifiedCookie(cookie)) {
        SmartDialog.showToast('会话验证失败或已切换账号');
        return;
      }
      SmartDialog.showToast('已同步哔哩哔哩账号');
    } catch (e) {
      SmartDialog.showToast("同步失败，请重试");
      Log.w("远程房间同步失败");
    }
  }

  Future<bool> showOverlayDialog() async {
    var overlay = await Utils.showAlertDialog(
      "是否覆盖远端数据？",
      title: "数据覆盖",
      confirm: "覆盖",
      cancel: "不覆盖",
    );
    return overlay;
  }

  void syncFollow() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("无设备连接");
        return;
      }

      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...");
      var users = DBService.instance.getFollowList();
      var data = json.encode(users.map((e) => e.toJson()).toList());

      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendFavorite",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送关注列表");
      } else {
        SmartDialog.showToast("发送失败，请重试");
      }
    } catch (e) {
      SmartDialog.showToast("发送失败:$e");
      Log.w("远程房间同步失败");
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncHistory() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("无设备连接");
        return;
      }
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...");
      var histores = DBService.instance.getHistores();
      var data = json.encode(histores.map((e) => e.toJson()).toList());
      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendHistory",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送历史记录");
      } else {
        SmartDialog.showToast("发送失败，请重试");
      }
    } catch (e) {
      SmartDialog.showToast("发送失败:$e");
      Log.w("远程房间同步失败");
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBlockedWord() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("无设备连接");
        return;
      }
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...");
      var shieldList = AppSettingsController.instance.shieldList;
      var data = json.encode(shieldList.toList());

      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendShieldWord",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送屏蔽词");
      } else {
        SmartDialog.showToast("发送失败，请重试");
      }
    } catch (e) {
      SmartDialog.showToast("发送失败:$e");
      Log.w("远程房间同步失败");
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBiliAccount() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("无设备连接");
        return;
      }
      if (!BiliBiliAccountService.instance.logined.value) {
        SmartDialog.showToast("未登录哔哩哔哩");
        return;
      }
      final room = currentRoomId.value;
      final peers = roomUsers.map((peer) => peer.connectionId).toSet();
      if (!await Utils.showAlertDialog(
        '将通过 ${Uri.parse(SignalRService.kUrl).host} 中转，把哔哩哔哩会话发送给房间 $room 内已连接的设备。',
        title: '发送哔哩哔哩账号',
      ))
        return;
      if (room != currentRoomId.value ||
          !roomUsers.every((peer) => peers.contains(peer.connectionId)) ||
          roomUsers.length != peers.length) {
        SmartDialog.showToast('房间设备已变化，请重新确认');
        return;
      }
      SmartDialog.showLoading(msg: "发送中...");

      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendBiliAccount",
        overlay: true,
        content: json.encode({
          "cookie": BiliBiliAccountService.instance.cookie,
        }),
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送哔哩哔哩账号");
      } else {
        SmartDialog.showToast("发送失败，请重试");
      }
    } catch (e) {
      SmartDialog.showToast("同步失败，请重试");
      Log.w("远程房间同步失败");
    } finally {
      SmartDialog.dismiss();
    }
  }

  void showQRInfo() {
    Utils.showBottomSheet(
      title: "房间信息",
      child: Column(
        children: [
          QrImageView(
            data: currentRoomId.value,
            version: QrVersions.auto,
            backgroundColor: Colors.white,
            padding: AppStyle.edgeInsetsA12,
            size: 200,
          ),
          AppStyle.vGap24,
          Text(
            currentRoomId.value,
            textAlign: TextAlign.center,
            style: Get.textTheme.titleLarge,
          ),
          const Text(
            "请使用其他Simple Live客户端扫描上方二维码\n建立连接后可选择需要同步的数据",
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  @override
  void onClose() {
    _timer?.cancel();
    _roomDestroyedSubscription?.cancel();
    _roomUserUpdatedSubscription?.cancel();
    _onFavoriteSubscription?.cancel();
    _onHistorySubscription?.cancel();
    _onShieldWordSubscription?.cancel();
    _onBiliAccountSubscription?.cancel();
    signalR.dispose();
    super.onClose();
  }
}
