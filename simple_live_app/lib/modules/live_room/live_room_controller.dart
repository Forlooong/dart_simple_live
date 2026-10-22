import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/live_room/chat_message_buffer.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({required this.pSite, required this.pRoomId}) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();
  final ChatMessageBuffer _chatBuffer = ChatMessageBuffer();
  Timer? _messageFlushTimer;
  Worker? _danmakuVisibilityWorker;
  Worker? _filterRulesWorker;
  bool _filterUpdating = false;
  int _filterRevision = 0;
  int? _pendingOnline;
  final _pendingSuperChats = <LiveSuperChatMessage>[];
  int _pendingSuperChatBytes = 0;
  bool _superChatOverflowed = false;
  bool _chatChanged = false;
  bool _scrollScheduled = false;
  bool _watchRegistered = false;
  bool _danmakuReady = false;
  final danmakuForeground = true.obs;

  bool get danmakuEnabled =>
      showDanmakuState.value && danmakuForeground.value && !playerClosing;

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

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间加载失败
  var loadError = false.obs;
  Object? error;
  StackTrace? errorStack;

  RequestContext? _sourceRequest;

  RequestContext _newSourceRequest() {
    _sourceRequest?.cancel();
    return _sourceRequest = RequestContext();
  }

  Future<void> _requestSource(Future<void> Function() operation) async {
    // The room -> qualities -> URLs chain shares one deadline and token.
    if (RequestContext.current != null &&
        identical(RequestContext.current, _sourceRequest)) {
      await operation();
      return;
    }
    if (playerClosing) return;
    final request = _newSourceRequest();
    try {
      await request.run(operation);
    } catch (error) {
      if (!identical(request, _sourceRequest) ||
          playerClosing ||
          (error is CoreError && error.kind == CoreErrorKind.cancelled)) {
        return;
      }
      errorMsg.value = '读取播放源失败，请刷新重试';
      showPlaybackFailure();
    }
  }

  int _roomGeneration = 0;
  int _playGeneration = 0;
  bool _playlistReady = false;
  int? _retryGeneration;
  int _mediaGeneration = 0;
  int? _failedMediaGeneration;
  int? _pendingRetryMediaGeneration;
  bool _recoveryExhausted = false;
  int _consecutiveRecoveryAttempts = 0;
  Duration? _firstPlaybackPosition;
  Duration? _lastPlaybackPosition;

  void _resetRecovery() {
    _failedMediaGeneration = null;
    _pendingRetryMediaGeneration = null;
    _recoveryExhausted = false;
    _consecutiveRecoveryAttempts = 0;
    mediaErrorRetryCount = 0;
  }

  bool _isCurrentRoom(int generation) =>
      !playerClosing && generation == _roomGeneration;

  bool _isCurrentSource(int generation) =>
      _isCurrentRoom(generation) &&
      !(RequestContext.current?.isCancelled ?? false);

  bool _isCurrentPlayback(int room, int playback) =>
      _isCurrentRoom(room) && playback == _playGeneration;

  void _invalidatePlayback({bool cancelSource = true}) {
    if (cancelSource) _sourceRequest?.cancel();
    _playGeneration++;
    _resetRecovery();
    _playlistReady = false;
    playUrls.clear();
    qualites.clear();
    currentQuality = -1;
    currentQualityInfo.value = "";
    currentLineIndex = -1;
    currentLineInfo.value = "";
    mediaErrorRetryCount = 0;
  }

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    if (Get.isRegistered<FollowService>()) {
      FollowService.instance.beginWatching();
      _watchRegistered = true;
    }
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      freezeChatHistory();
    }
  }

  /// The visible RxList is already a bounded copy; stop publishing into it.
  void freezeChatHistory() {
    disableAutoScroll.value = true;
  }

  void showLatestMessages() {
    if (playerClosing) return;
    disableAutoScroll.value = false;
    if (_filterUpdating || isBackground) {
      _chatChanged = true;
      return;
    }
    messages.value = _chatBuffer.latest.toList();
    _chatBuffer.markPublished();
    _chatChanged = false;
    _scheduleChatScroll();
  }

  void _scheduleChatScroll() {
    if (_scrollScheduled || isBackground || disableAutoScroll.value) return;
    _scrollScheduled = true;
    final generation = _roomGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (_isCurrentRoom(generation) && !isBackground) chatScrollToBottom();
    });
  }

  void _scheduleMessageFlush() {
    if (_messageFlushTimer != null ||
        isBackground ||
        playerClosing ||
        _filterUpdating) {
      return;
    }
    final generation = _roomGeneration;
    _messageFlushTimer = Timer(const Duration(milliseconds: 50), () {
      _messageFlushTimer = null;
      if (!_isCurrentRoom(generation) || isBackground || _filterUpdating) {
        return;
      }
      final batch = _chatBuffer.takeOverlay();
      if (_chatChanged && !disableAutoScroll.value) {
        messages.value = _chatBuffer.latest.toList();
        _scheduleChatScroll();
      }
      if (!disableAutoScroll.value) _chatBuffer.clearPending();
      _chatChanged = false;
      if (liveStatus.value && danmakuEnabled) {
        addDanmaku(batch
            .map((message) => DanmakuContentItem(
                  message.message,
                  color: Color.fromARGB(
                      255, message.color.r, message.color.g, message.color.b),
                ))
            .toList(growable: false));
      }
      if (_pendingOnline != null) {
        online.value = _pendingOnline!;
        _pendingOnline = null;
      }
      if (_pendingSuperChats.isNotEmpty) {
        final now = DateTime.now();
        final visible = superChats
            .where((message) => message.endTime.isAfter(now))
            .toList();
        var bytes =
            visible.fold(0, (sum, message) => sum + _superChatBytes(message));
        for (final message in _pendingSuperChats) {
          if (!message.endTime.isAfter(now)) continue;
          final messageBytes = _superChatBytes(message);
          if (bytes + messageBytes > 1024 * 1024) {
            _handleSuperChatOverflow();
            break;
          }
          visible.add(message);
          bytes += messageBytes;
        }
        superChats.value = visible;
        _pendingSuperChats.clear();
        _pendingSuperChatBytes = 0;
      }
    });
  }

  void _queueChat(LiveMessage message, {bool overlay = true}) {
    if (_chatBuffer.add(message,
        overlay: overlay && liveStatus.value && danmakuEnabled,
        filter: overlay)) {
      _chatChanged = true;
      _scheduleMessageFlush();
    }
  }

  void _invalidateMessageBatch({bool clearHistory = false}) {
    ++_filterRevision;
    _filterUpdating = false;
    _messageFlushTimer?.cancel();
    _messageFlushTimer = null;
    _chatBuffer.discardUnpublished();
    _pendingOnline = null;
    _pendingSuperChats.clear();
    _pendingSuperChatBytes = 0;
    _superChatOverflowed = false;
    if (clearHistory) {
      _chatBuffer.clear();
      messages.clear();
      _chatChanged = false;
      disableAutoScroll.value = false;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog(
          "定时关闭已到时,是否延迟关闭?",
          title: "延迟关闭",
          confirm: "延迟",
          cancel: "关闭",
          selectable: true,
        );
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    superChats.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    _danmakuReady = false;
    _danmakuVisibilityWorker ??= ever<bool>(showDanmakuState, (visible) {
      danmakuController?.setEnabled(danmakuEnabled);
      if (!visible) {
        _chatBuffer.discardOverlay();
        danmakuController?.clear();
      }
    });
    final generation = _roomGeneration;
    _filterRulesWorker ??= ever<Set<String>>(
      AppSettingsController.instance.shieldList,
      (_) => _updateDanmakuFilter(),
    );
    liveDanmaku.onMessage = (message) {
      if (_isCurrentRoom(generation)) onWSMessage(message);
    };
    liveDanmaku.onMessages = (batch) {
      if (!_isCurrentRoom(generation)) return;
      for (final message in batch) {
        onWSMessage(message);
      }
    };
    liveDanmaku.onDiagnostic = (diagnostic) {
      if (_isCurrentRoom(generation)) addSysMsg(diagnostic);
    };
    liveDanmaku.onClose = (message) {
      if (_isCurrentRoom(generation)) onWSClose(message);
    };
    liveDanmaku.onReady = () {
      if (_isCurrentRoom(generation)) onWSReady();
    };
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
      if (!_isCurrentRoom(generation) || revision != _filterRevision) return;
      final pending = _chatBuffer.unfilteredPending;
      final accepted = await liveDanmaku.refilterMessages(pending);
      if (!_isCurrentRoom(generation) || revision != _filterRevision) return;
      _chatBuffer.applyFilterResult(pending, accepted);
      _chatChanged = true;
    } catch (error) {
      if (_isCurrentRoom(generation) && revision == _filterRevision) {
        _chatBuffer.applyFilterResult(_chatBuffer.unfilteredPending, const []);
        _chatChanged = true;
        addSysMsg('弹幕过滤规则加载失败：$error');
      }
    } finally {
      if (_isCurrentRoom(generation) && revision == _filterRevision) {
        _filterUpdating = false;
        _scheduleMessageFlush();
      }
    }
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (playerClosing) return;
    if (msg.type == LiveMessageType.chat) {
      // 关键词屏蔽检查
      _queueChat(msg);
    } else if (msg.type == LiveMessageType.online) {
      _pendingOnline = msg.data;
      _scheduleMessageFlush();
    } else if (msg.type == LiveMessageType.superChat) {
      _queueSuperChat(msg.data as LiveSuperChatMessage);
    }
  }

  int _superChatBytes(LiveSuperChatMessage message) =>
      (message.userName.length +
              message.message.length +
              message.face.length +
              message.backgroundColor.length +
              message.backgroundBottomColor.length) *
          2 +
      256;

  void _handleSuperChatOverflow() {
    if (_superChatOverflowed) return;
    _superChatOverflowed = true;
    addSysMsg('醒目留言队列已达上限，弹幕连接已停止，请刷新直播间');
    liveDanmaku.stop();
  }

  void _queueSuperChat(LiveSuperChatMessage message) {
    if (_superChatOverflowed || !message.endTime.isAfter(DateTime.now())) {
      return;
    }
    final bytes = _superChatBytes(message);
    if (_pendingSuperChatBytes + bytes > 1024 * 1024) {
      _handleSuperChatOverflow();
      return;
    }
    _pendingSuperChats.add(message);
    _pendingSuperChatBytes += bytes;
    _scheduleMessageFlush();
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    if (playerClosing) return;
    _queueChat(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
      overlay: false,
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    if (_danmakuReady) {
      _invalidateMessageBatch();
      unawaited(_updateDanmakuFilter());
    }
    _danmakuReady = true;
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  Future<void> loadData() => _requestSource(_loadData);

  Future<void> _loadData() async {
    if (playerClosing) return;
    final generation = ++_roomGeneration;
    _invalidateMessageBatch();
    final requestedSite = site;
    final requestedRoom = roomId;
    _invalidatePlayback(cancelSource: false);
    _liveDurationTimer?.cancel();
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      errorStack = null;
      update();
      addSysMsg("正在读取直播间信息");
      final roomDetail = await playbackDiagnostics.measure(
        PlaybackStage.room,
        () => requestedSite.liveSite.getRoomDetail(roomId: requestedRoom),
      );
      if (!_isCurrentRoom(generation)) return;
      detail.value = roomDetail;

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            final oldFollowId = "${site.id}_$oldId";
            final newFollowId = "${site.id}_$roomId";
            final oldFollow = DBService.instance.followBox.get(oldFollowId);
            final existingFollow =
                DBService.instance.followBox.get(newFollowId);
            // 先保存新 ID，避免迁移失败时丢失原关注及开播提醒选择。
            await DBService.instance.addFollow(
              FollowUser(
                id: newFollowId,
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: oldFollow?.addTime ??
                    existingFollow?.addTime ??
                    DateTime.now(),
                tag: oldFollow?.tag ?? existingFollow?.tag ?? "全部",
                notifyLive: (oldFollow?.notifyLive ?? false) ||
                    (existingFollow?.notifyLive ?? false),
              ),
            );
            // 标签另外保存关注 ID，也需要一同迁移。
            for (final tag in DBService.instance.getFollowTagList()) {
              if (tag.userId.contains(oldFollowId)) {
                await DBService.instance.updateFollowTag(
                  tag.copyWith(
                    userId: tag.userId
                        .map((id) => id == oldFollowId ? newFollowId : id)
                        .toSet()
                        .toList(),
                  ),
                );
              }
            }
            await DBService.instance.deleteFollow(oldFollowId);
            if (!_isCurrentRoom(generation)) return;
            EventBus.instance.emit(Constant.kUpdateFollow, newFollowId);
          } else {
            followed.value = DBService.instance.getFollowExist(
              "${site.id}_$roomId",
            );
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        await getPlayQualites(generation);
      } else {
        // A manual refresh can confirm that the current stream is offline.
        // Invalidating its URL state alone does not unload native playback.
        await runPlayerCommand(() async {
          if (_isCurrentRoom(generation)) await player.stop();
        });
        if (!_isCurrentRoom(generation)) return;
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      unawaited(_startDanmaku(generation, detail.value?.danmakuData));
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e, stack) {
      if (RequestContext.current?.isCancelled ?? false) return;
      if (!_isCurrentRoom(generation)) return;
      Log.logPrint(e);
      loadError.value = true;
      error = e;
      errorStack = stack;
    } finally {
      if (_isCurrentRoom(generation)) {
        SmartDialog.dismiss(status: SmartStatus.loading);
      }
    }
  }

  Future<void> _startDanmaku(int generation, dynamic data) async {
    try {
      await liveDanmaku.start(data);
    } catch (error) {
      if (_isCurrentRoom(generation)) {
        Log.logPrint(error);
        addSysMsg('弹幕启动失败，请刷新直播间重试：$error');
      }
    }
  }

  /// 初始化播放器
  Future<void> getPlayQualites([int? roomGeneration]) =>
      _requestSource(() => _getPlayQualites(roomGeneration));

  Future<void> _getPlayQualites(int? roomGeneration) async {
    final generation = roomGeneration ?? _roomGeneration;
    if (!_isCurrentSource(generation) || detail.value == null) return;
    final requestedSite = site;
    final requestedDetail = detail.value!;
    qualites.clear();
    currentQuality = -1;
    try {
      final qualities = await playbackDiagnostics.measure(
        PlaybackStage.quality,
        () => requestedSite.liveSite.getPlayQualites(detail: requestedDetail),
      );
      if (!_isCurrentSource(generation)) return;
      if (qualities.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      final qualityLevel = await getQualityLevel();
      if (!_isCurrentSource(generation)) return;
      qualites.value = qualities;
      currentQuality = qualityLevel == 2
          ? 0
          : qualityLevel == 0
              ? qualities.length - 1
              : qualities.length ~/ 2;
      await getPlayUrl();
    } catch (e) {
      if (!_isCurrentSource(generation)) return;
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  Future<void> getPlayUrl() => _requestSource(_getPlayUrl);

  Future<void> _getPlayUrl() async {
    if (playerClosing ||
        detail.value == null ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      return;
    }
    final room = _roomGeneration;
    final playback = ++_playGeneration;
    _resetRecovery();
    final requestedSite = site;
    final requestedDetail = detail.value!;
    final quality = qualites[currentQuality];
    _playlistReady = false;
    playUrls.clear();
    currentQualityInfo.value = quality.quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    try {
      final playUrl = await playbackDiagnostics.measure(
        PlaybackStage.urls,
        () => requestedSite.liveSite.getPlayUrls(
          detail: requestedDetail,
          quality: quality,
        ),
      );
      if (!_isCurrentPlayback(room, playback)) return;
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        return;
      }
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      currentLineIndex = 0;
      mediaErrorRetryCount = 0;
      await initPlaylist();
    } catch (e) {
      if (!_isCurrentPlayback(room, playback)) return;
      Log.logPrint(e);
      errorMsg.value = "无法读取或打开播放地址";
      SmartDialog.showToast(errorMsg.value);
      if (_playlistReady) mediaError(errorMsg.value);
    }
  }

  void changePlayLine(int index) {
    if (playerClosing ||
        !_playlistReady ||
        index < 0 ||
        index >= playUrls.length) {
      return;
    }
    _sourceRequest?.cancel();
    // Invalidate any delayed retry for the previous selection.
    _playGeneration++;
    _resetRecovery();
    currentLineIndex = index;
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<void> initPlaylist() async {
    final room = _roomGeneration;
    final playback = _playGeneration;
    if (!_isCurrentPlayback(room, playback) || playUrls.isEmpty) return;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";
    final media = _mediaForLine(currentLineIndex);
    await runPlayerCommand(() async {
      if (!_isCurrentPlayback(room, playback)) return;
      await initializePlayer();
      if (!_isCurrentPlayback(room, playback)) return;
      // A failure belongs to one native open, not to the whole room. An old
      // error + EOF pair must not consume another attempt during URL refresh.
      _mediaGeneration++;
      _failedMediaGeneration = null;
      _firstPlaybackPosition = null;
      _lastPlaybackPosition = null;
      _playlistReady = true;
      // CDN alternatives are not consecutive programmes. Keep libmpv from
      // advancing to another line independently of application recovery.
      // open() also avoids jump() -> play() -> seek(0) on an ended live FLV.
      playbackDiagnostics.opened();
      await playbackDiagnostics.measure(
        PlaybackStage.open,
        () => player.open(media),
      );
    });
  }

  Media _mediaForLine(int index) {
    final url = playUrls[index];
    final finalUrl = AppSettingsController.instance.playerForceHttps.value
        ? url.replaceFirst("http://", "https://")
        : url;
    return Media(finalUrl, httpHeaders: playHeaders);
  }

  Future<void> setPlayer() async {
    final room = _roomGeneration;
    final playback = _playGeneration;
    final index = currentLineIndex;
    if (!_playlistReady ||
        !_isCurrentPlayback(room, playback) ||
        index < 0 ||
        index >= playUrls.length) {
      return;
    }
    try {
      await initPlaylist();
    } catch (e) {
      if (!_isCurrentPlayback(room, playback)) return;
      Log.logPrint(e);
      errorMsg.value = "播放失败";
      mediaError(errorMsg.value);
    }
  }

  @override
  void mediaEnd() {
    if (playerClosing || !_playlistReady) return;
    playbackDiagnostics.terminal(PlaybackTerminal.eof);
    super.mediaEnd();
    _retryPlayback();
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) {
    if (playerClosing || !_playlistReady) return;
    playbackDiagnostics.terminal(PlaybackTerminal.error);
    super.mediaError(error);
    _retryPlayback();
  }

  Future<void> _retryPlayback() async {
    if (playerClosing ||
        !_playlistReady ||
        _recoveryExhausted ||
        currentLineIndex < 0 ||
        currentLineIndex >= playUrls.length) {
      return;
    }
    if (_failedMediaGeneration == _mediaGeneration) return;
    _failedMediaGeneration = _mediaGeneration;
    if (_retryGeneration == _playGeneration) {
      // Only a failure of the newly opened media needs another attempt.
      // Duplicates from the old media have already returned above.
      _pendingRetryMediaGeneration = _mediaGeneration;
      return;
    }
    await _recoverPlayback();
  }

  Future<void> _recoverPlayback() async {
    final room = _roomGeneration;
    final playback = _playGeneration;
    _retryGeneration = playback;
    try {
      while (_isCurrentPlayback(room, playback) && !_recoveryExhausted) {
        // Two attempts per line, at most six without sustained playback.
        // Refreshing a URL must not reset this budget.
        if (_consecutiveRecoveryAttempts >= 6 ||
            (mediaErrorRetryCount >= 2 &&
                currentLineIndex + 1 >= playUrls.length)) {
          _recoveryExhausted = true;
          errorMsg.value = "播放失败，请刷新直播间重试";
          Log.w("播放恢复已停止：已达到重试上限");
          showPlaybackFailure();
          return;
        }
        if (mediaErrorRetryCount >= 2) {
          currentLineIndex++;
          mediaErrorRetryCount = 0;
        }
        mediaErrorRetryCount++;
        final attempt = ++_consecutiveRecoveryAttempts;
        // Give the old stream's error/EOF notifications time to drain before
        // replacing it, and avoid repeatedly rebuilding the native decoder.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!_isCurrentPlayback(room, playback)) return;
        playbackDiagnostics.recoveryAttempt();
        Log.i("播放恢复：第 $attempt 次，重新获取直播地址");
        try {
          final request = _newSourceRequest();
          if (!await request.run(
            () => _refreshPlaybackSource(room, playback),
          )) {
            return;
          }
          await initPlaylist();
          return;
        } catch (e, stack) {
          if (!_isCurrentPlayback(room, playback)) return;
          Log.e("播放恢复失败：${e.runtimeType}", stack);
          if (e is CoreError && !e.retriable) {
            if (e.kind == CoreErrorKind.cancelled) return;
            _recoveryExhausted = true;
            errorMsg.value = e.toString();
            showPlaybackFailure();
            return;
          }
          // HTTP/open exceptions may not emit a native terminal event.
          // Retry them here, under the same bounded recovery owner.
        }
      }
    } finally {
      if (_retryGeneration == playback) _retryGeneration = null;
      if (_isCurrentPlayback(room, playback)) {
        final pending = _pendingRetryMediaGeneration;
        _pendingRetryMediaGeneration = null;
        if (!_recoveryExhausted && pending == _mediaGeneration) {
          unawaited(_recoverPlayback());
        }
      }
    }
  }

  Future<bool> _refreshPlaybackSource(int room, int playback) async {
    final requestedSite = site;
    final selectedQuality = qualites[currentQuality];
    final selectedIndex = currentQuality;
    // Douyu keeps its timestamped signing arguments in detail.data; Douyin
    // keeps URLs in quality.data. Refresh the whole source, not only the URL.
    final freshDetail = await playbackDiagnostics.measure(
      PlaybackStage.room,
      () => requestedSite.liveSite.getRoomDetail(roomId: roomId),
    );
    if (!_isCurrentPlayback(room, playback)) return false;
    if (!freshDetail.status && !freshDetail.isRecord) {
      _recoveryExhausted = true;
      _playlistReady = false;
      liveStatus.value = false;
      await runPlayerCommand(() async {
        if (_isCurrentPlayback(room, playback)) await player.stop();
      });
      return false;
    }
    final freshQualities = await playbackDiagnostics.measure(
      PlaybackStage.quality,
      () => requestedSite.liveSite.getPlayQualites(detail: freshDetail),
    );
    if (!_isCurrentPlayback(room, playback)) return false;
    if (freshQualities.isEmpty) throw StateError('No live qualities');
    var qualityIndex = selectedQuality.id == null
        ? -1
        : freshQualities.indexWhere((item) => item.id == selectedQuality.id);
    if (qualityIndex < 0) {
      qualityIndex = freshQualities.indexWhere(
        (item) => item.quality == selectedQuality.quality,
      );
    }
    if (qualityIndex < 0) {
      qualityIndex = selectedIndex.clamp(0, freshQualities.length - 1);
    }
    final freshUrls = await playbackDiagnostics.measure(
      PlaybackStage.urls,
      () => requestedSite.liveSite.getPlayUrls(
        detail: freshDetail,
        quality: freshQualities[qualityIndex],
      ),
    );
    if (!_isCurrentPlayback(room, playback)) return false;
    if (freshUrls.urls.isEmpty) throw StateError('No live URLs');
    detail.value = freshDetail;
    qualites.value = freshQualities;
    currentQuality = qualityIndex;
    currentQualityInfo.value = freshQualities[qualityIndex].quality;
    playUrls.value = freshUrls.urls;
    playHeaders = freshUrls.headers;
    currentLineIndex = currentLineIndex.clamp(0, playUrls.length - 1);
    return true;
  }

  @override
  void mediaPosition(Duration position) {
    if (playerClosing ||
        !_playlistReady ||
        _failedMediaGeneration == _mediaGeneration) {
      return;
    }
    if (_firstPlaybackPosition == null ||
        (_lastPlaybackPosition != null && position < _lastPlaybackPosition!)) {
      _firstPlaybackPosition = position;
    }
    _lastPlaybackPosition = position;
    // playing=true is emitted before a decoder has produced any frames.
    // Only advancing media time replenishes the automatic recovery budget.
    if (position - _firstPlaybackPosition! >= const Duration(seconds: 10)) {
      mediaErrorRetryCount = 0;
      _consecutiveRecoveryAttempts = 0;
    }
  }

  void showPlaybackFailure() {
    SmartDialog.showToast(errorMsg.value);
  }

  @override
  Future<void> closePlayer() {
    _sourceRequest?.cancel();
    return super.closePlayer();
  }

  /// 读取SC
  void getSuperChatMessage() async {
    final generation = _roomGeneration;
    try {
      var sc = await site.liveSite.getSuperChatMessage(
        roomId: detail.value!.roomId,
      );
      if (!_isCurrentRoom(generation)) return;
      for (final message in sc) {
        _queueSuperChat(message);
      }
    } catch (e) {
      if (!_isCurrentRoom(generation)) return;
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    if (playerClosing || isBackground) return;
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
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
  Future<void> followUser() async {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    await DBService.instance.addFollow(
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
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    await DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite.getPlayUrls(
      detail: detail.value!,
      quality: qualites[currentQuality],
    );
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  runPlayerCommand(
                    () => player.setVolume(newValue),
                  ).catchError((Object error) => Log.logPrint(error));
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(value: i, title: Text(item.quality));
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(playUrls[i].contains(".flv") ? "FLV" : "HLS"),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() async {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      final rule = keywordController.text.trim();
      if (await AppSettingsController.instance.addValidatedShieldRule(rule) &&
          keywordController.text.trim() == rule) {
        keywordController.text = "";
      }
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(item, style: Get.textTheme.bodyMedium),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(Sites.allSites[item.siteId]!, item.roomId);
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text("启用定时关闭", style: Get.textTheme.titleMedium),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration = Duration(
                  hours: value.hour,
                  minutes: value.minute,
                );
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance.setRoomAutoExitDuration(
                  autoExitMinutes.value,
                );
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (playerClosing || (this.site == site && this.roomId == roomId)) {
      return;
    }

    final generation = ++_roomGeneration;
    _invalidatePlayback();
    _liveDurationTimer?.cancel();
    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    _invalidateMessageBatch(clearHistory: true);
    superChats.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    try {
      await runPlayerCommand(() async {
        if (_isCurrentRoom(generation)) await player.stop();
      });
    } catch (e) {
      Log.logPrint(e);
    }
    if (!_isCurrentRoom(generation)) return;
    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
$errorStack''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (playerClosing) {
      danmakuController?.setEnabled(false);
      return;
    }

    if (state != AppLifecycleState.resumed) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
      danmakuForeground.value = false;
      danmakuController?.setEnabled(false);
      _messageFlushTimer?.cancel();
      _messageFlushTimer = null;
      _chatBuffer.discardOverlay();
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

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    ++_roomGeneration;
    danmakuForeground.value = false;
    _invalidateMessageBatch(clearHistory: true);
    _danmakuVisibilityWorker?.dispose();
    _filterRulesWorker?.dispose();
    if (_watchRegistered && Get.isRegistered<FollowService>()) {
      FollowService.instance.endWatching();
      _watchRegistered = false;
    }
    _invalidatePlayback();
    try {
      SmartDialog.dismiss(status: SmartStatus.loading);
      WidgetsBinding.instance.removeObserver(this);
      scrollController.removeListener(scrollListener);
      scrollController.dispose();
      autoExitTimer?.cancel();
      _liveDurationTimer?.cancel();
      liveDanmaku.stop();
    } finally {
      super.onClose();
      danmakuController = null;
    }
  }
}
