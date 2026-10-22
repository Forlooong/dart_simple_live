import 'package:simple_live_tv_app/services/sync_service.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/signalr_service.dart';

class SyncController extends BaseController {
  final SignalRService signalR = SignalRService();
  StreamSubscription? _stateSubscription;
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

  Rx<SignalRConnectionState> state = Rx<SignalRConnectionState>(
    SignalRConnectionState.connecting,
  );

  @override
  void onInit() {
    unawaited(SyncService.instance.startSession());
    connect();
    super.onInit();
  }

  void connect() async {
    listenSignalR();
    await signalR.connect();
    if (signalR.state == SignalRConnectionState.connected) {
      createRoom();
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

  void listenSignalR() {
    _stateSubscription = signalR.stateStream.listen((event) {
      state.value = event;
    });
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
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveHistory(bool overlay, String data) async {
    try {
      final jsonBody = json.decode(data) as List;
      await DBService.instance.importHistories(jsonBody, replace: overlay);
      SmartDialog.showToast('已同步历史记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveShieldWord(bool overlay, String data) async {
    try {
      final jsonBody = json.decode(data) as List;
      await AppSettingsController.instance.importShieldRules(
          jsonBody, replace: overlay);
      SmartDialog.showToast('已同步屏蔽词');
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveBiliAccount(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      var cookie = jsonBody['cookie'];
      await BiliBiliAccountService.instance.setCookie(cookie);
      await BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号');
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  @override
  void onClose() {
    unawaited(SyncService.instance.stopSession());
    _timer?.cancel();
    _stateSubscription?.cancel();
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
