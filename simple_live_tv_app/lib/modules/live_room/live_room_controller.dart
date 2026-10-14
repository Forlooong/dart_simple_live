import 'dart:async';
import 'dart:collection';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({required this.pSite, required this.pRoomId}) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
  }
  final FocusNode focusNode = FocusNode();
  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  final danmakuForeground = true.obs;
  final _pendingMessages = ListQueue<LiveMessage>();
  int _pendingBytes = 0;
  int droppedDanmakuMessages = 0;
  int? _pendingOnline;
  String? _pendingDiagnostic;
  int _roomGeneration = 0;
  bool _closing = false;
  bool _watchRegistered = false;
  bool _danmakuReady = false;
  Timer? _messageFlushTimer;
  Timer? _clockTimer;
  Worker? _danmakuVisibilityWorker;
  Worker? _filterRulesWorker;
  int _filterRevision = 0;
  bool _filterUpdating = false;

  bool get danmakuEnabled =>
      showDanmakuState.value && danmakuForeground.value && !_closing;

  int _messageBytes(LiveMessage message) =>
      (message.message.length + message.userName.length) * 2 + 128;

  void _clearPendingMessages() {
    _pendingMessages.clear();
    _pendingBytes = 0;
  }

  void _invalidateMessages() {
    ++_filterRevision;
    _filterUpdating = false;
    _messageFlushTimer?.cancel();
    _messageFlushTimer = null;
    _clearPendingMessages();
    _pendingOnline = null;
    _pendingDiagnostic = null;
  }

  void _scheduleMessageFlush() {
    if (_messageFlushTimer != null ||
        isBackground ||
        _closing ||
        _filterUpdating) {
      return;
    }
    final generation = _roomGeneration;
    _messageFlushTimer = Timer(const Duration(milliseconds: 50), () {
      _messageFlushTimer = null;
      if (_closing ||
          generation != _roomGeneration ||
          isBackground ||
          _filterUpdating) {
        return;
      }
      if (liveStatus.value && danmakuEnabled) {
        addDanmaku(
          _pendingMessages
              .map(
                (message) => DanmakuContentItem(
                  message.message,
                  color: Color.fromARGB(
                    255,
                    message.color.r,
                    message.color.g,
                    message.color.b,
                  ),
                ),
              )
              .toList(growable: false),
        );
      }
      _clearPendingMessages();
      if (_pendingOnline != null) {
        online.value = _pendingOnline!;
        _pendingOnline = null;
      }
      if (_pendingDiagnostic != null) {
        SmartDialog.showToast(_pendingDiagnostic!);
        _pendingDiagnostic = null;
      }
    });
  }

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 是否处于后台
  var isBackground = false;

  var datetime = "00:00".obs;

  void initTimer() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  /// 双击退出Flag
  bool doubleClickExit = false;

  /// 双击退出Timer
  Timer? doubleClickTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    if (Get.isRegistered<FollowUserService>()) {
      FollowUserService.instance.beginWatching();
      _watchRegistered = true;
    }
    initTimer();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");

    loadData();

    super.onInit();
  }

  void refreshRoom() {
    //messages.clear();

    liveDanmaku.stop();

    loadData();
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    _danmakuReady = false;
    _danmakuVisibilityWorker ??= ever<bool>(showDanmakuState, (visible) {
      danmakuController?.setEnabled(danmakuEnabled);
      if (!visible) {
        _clearPendingMessages();
        danmakuController?.clear();
      }
    });
    final generation = _roomGeneration;
    liveDanmaku.onReady = () {
      if (_closing || generation != _roomGeneration) return;
      if (_danmakuReady) {
        _invalidateMessages();
        unawaited(_updateDanmakuFilter());
      }
      _danmakuReady = true;
    };
    liveDanmaku.onMessage = (message) {
      if (!_closing && generation == _roomGeneration) onWSMessage(message);
    };
    liveDanmaku.onMessages = (batch) {
      if (_closing || generation != _roomGeneration) return;
      for (final message in batch) {
        onWSMessage(message);
      }
    };
    liveDanmaku.onDiagnostic = (diagnostic) {
      if (_closing || generation != _roomGeneration) return;
      _reportDanmakuDiagnostic(diagnostic);
    };
    _filterRulesWorker ??= ever<Set<String>>(
      AppSettingsController.instance.shieldList,
      (_) => _updateDanmakuFilter(),
    );
    unawaited(_updateDanmakuFilter());
  }

  Future<void> _updateDanmakuFilter() async {
    final generation = _roomGeneration;
    final revision = ++_filterRevision;
    _filterUpdating = true;
    _messageFlushTimer?.cancel();
    _messageFlushTimer = null;
    final rules = AppSettingsController.instance.shieldList.map((text) {
      final regex = Utils.isRegexFormat(text);
      return DanmakuFilterRule(
        text: regex ? Utils.removeRegexFormat(text) : text,
        regex: regex,
      );
    }).toList(growable: false);
    try {
      await liveDanmaku.updateFilterRules(rules);
      if (_closing ||
          generation != _roomGeneration ||
          revision != _filterRevision) {
        return;
      }
      final pending = _pendingMessages.toList(growable: false);
      final accepted = await liveDanmaku.refilterMessages(pending);
      if (_closing ||
          generation != _roomGeneration ||
          revision != _filterRevision) {
        return;
      }
      final rejected = pending.toSet()..removeAll(accepted);
      _pendingMessages.removeWhere(rejected.contains);
      _pendingBytes = _pendingMessages.fold(
          0, (sum, message) => sum + _messageBytes(message));
    } catch (error) {
      if (!_closing &&
          generation == _roomGeneration &&
          revision == _filterRevision) {
        _clearPendingMessages();
        _reportDanmakuDiagnostic('弹幕过滤规则加载失败：$error');
      }
    } finally {
      if (!_closing &&
          generation == _roomGeneration &&
          revision == _filterRevision) {
        _filterUpdating = false;
        _scheduleMessageFlush();
      }
    }
  }

  void _reportDanmakuDiagnostic(String diagnostic) {
    Log.w(diagnostic);
    _pendingDiagnostic =
        diagnostic.length > 4096 ? diagnostic.substring(0, 4096) : diagnostic;
    _scheduleMessageFlush();
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (_closing) return;
    if (msg.type == LiveMessageType.chat) {
      // 关键词屏蔽检查
      if (!liveStatus.value || !danmakuEnabled) {
        return;
      }

      final bytes = _messageBytes(msg);
      if (bytes > 1024 * 1024) {
        droppedDanmakuMessages++;
        return;
      }
      _pendingMessages.addLast(msg);
      _pendingBytes += bytes;
      while (_pendingMessages.length > 200 || _pendingBytes > 1024 * 1024) {
        _pendingBytes -= _messageBytes(_pendingMessages.removeFirst());
        droppedDanmakuMessages++;
      }
      _scheduleMessageFlush();
    } else if (msg.type == LiveMessageType.online) {
      _pendingOnline = msg.data;
      _scheduleMessageFlush();
    } else if (msg.type == LiveMessageType.superChat) {
      //superChats.add(msg.data);
    }
  }

  /// 加载直播间信息
  void loadData() async {
    if (_closing) return;
    final generation = ++_roomGeneration;
    _invalidateMessages();
    try {
      SmartDialog.showLoading(msg: "");
      pageLoadding.value = true;
      final roomDetail = await site.liveSite.getRoomDetail(roomId: roomId);
      if (_closing || generation != _roomGeneration) return;
      detail.value = roomDetail;

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      unawaited(_startDanmaku(generation, detail.value?.danmakuData));
    } catch (e) {
      if (_closing || generation != _roomGeneration) return;
      SmartDialog.showToast(e.toString());
    } finally {
      if (!_closing && generation == _roomGeneration) {
        SmartDialog.dismiss(status: SmartStatus.loading);
        pageLoadding.value = false;
      }
    }
  }

  Future<void> _startDanmaku(int generation, dynamic data) async {
    try {
      await liveDanmaku.start(data);
    } catch (error) {
      if (!_closing && generation == _roomGeneration) {
        Log.logPrint(error);
        _reportDanmakuDiagnostic('弹幕启动失败，请刷新直播间重试：$error');
      }
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;
    try {
      var playQualites = await site.liveSite.getPlayQualites(
        detail: detail.value!,
      );

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = AppSettingsController.instance.qualityLevel.value;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  void getPlayUrl() async {
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    var playUrl = await site.liveSite.getPlayUrls(
      detail: detail.value!,
      quality: qualites[currentQuality],
    );
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    playUrls.value = playUrl.urls;
    playHeaders = playUrl.headers;
    currentLineIndex = 0;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  void setPlayer() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";
    // 初始化播放器并设置 ao 参数
    await initializePlayer();
    player.open(Media(playUrls[currentLineIndex], httpHeaders: playHeaders));

    Log.d("播放链接\r\n：${playUrls[currentLineIndex]}");
  }

  @override
  void mediaEnd() async {
    if (mediaErrorRetryCount < 2) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    Log.d("播放结束");
    // 遍历线路，如果全部链接都断开就是直播结束了
    if (playUrls.length - 1 == currentLineIndex) {
      liveStatus.value = false;
    } else {
      changePlayLine(currentLineIndex + 1);

      //setPlayer();
    }
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    if (mediaErrorRetryCount < 2) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
    } else {
      //currentLineIndex += 1;
      //setPlayer();
      changePlayLine(currentLineIndex + 1);
    }
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已关注");
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    // if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
    //   return;
    // }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
  }

  void resetRoom(Site site, String roomId) async {
    if (_closing || (this.site == site && this.roomId == roomId)) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;
    final generation = ++_roomGeneration;
    _invalidateMessages();

    // 清除全部消息
    liveDanmaku.stop();

    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();
    if (_closing || generation != _roomGeneration) return;

    // 刷新信息
    loadData();
  }

  void nextChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels.indexWhere(
      (element) => element.id == "${site.id}_$roomId",
    );
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index += 1;
    if (index >= liveChannels.length) {
      index = 0;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  void prevChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels.indexWhere(
      (element) => element.id == "${site.id}_$roomId",
    );
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index -= 1;
    if (index < 0) {
      index = liveChannels.length - 1;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_closing) return;

    if (state != AppLifecycleState.resumed) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
      danmakuForeground.value = false;
      danmakuController?.setEnabled(false);
      _messageFlushTimer?.cancel();
      _messageFlushTimer = null;
      _clearPendingMessages();
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
      danmakuForeground.value = true;
      danmakuController?.setEnabled(danmakuEnabled);
      _scheduleMessageFlush();
    }
  }

  @override
  void onClose() {
    _closing = true;
    ++_roomGeneration;
    danmakuForeground.value = false;
    _invalidateMessages();
    _clockTimer?.cancel();
    doubleClickTimer?.cancel();
    _danmakuVisibilityWorker?.dispose();
    _filterRulesWorker?.dispose();
    SmartDialog.dismiss(status: SmartStatus.loading);
    WidgetsBinding.instance.removeObserver(this);
    if (_watchRegistered && Get.isRegistered<FollowUserService>()) {
      FollowUserService.instance.endWatching();
      _watchRegistered = false;
    }
    liveDanmaku.stop();
    focusNode.dispose();
    danmakuController?.clear();
    danmakuController = null;
    super.onClose();
  }
}
