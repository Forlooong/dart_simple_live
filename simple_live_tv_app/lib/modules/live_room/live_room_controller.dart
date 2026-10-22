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
      !_closing && !playerClosing && generation == _roomGeneration;

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
  Future<void> loadData() => _requestSource(_loadData);

  Future<void> _loadData() async {
    if (_closing) return;
    final generation = ++_roomGeneration;
    _invalidatePlayback(cancelSource: false);
    _invalidateMessages();
    final requestedSite = site;
    final requestedRoom = roomId;
    try {
      SmartDialog.showLoading(msg: "");
      pageLoadding.value = true;
      final roomDetail = await playbackDiagnostics.measure(
        PlaybackStage.room,
        () => requestedSite.liveSite.getRoomDetail(roomId: requestedRoom),
      );
      if (!_isCurrentRoom(generation)) return;
      detail.value = roomDetail;

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        await getPlayQualites(generation);
      } else {
        await runPlayerCommand(() async {
          if (_isCurrentRoom(generation)) await player.stop();
        });
      }
      if (!_isCurrentRoom(generation)) return;
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      unawaited(_startDanmaku(generation, detail.value?.danmakuData));
    } catch (e) {
      if (RequestContext.current?.isCancelled ?? false) return;
      if (!_isCurrentRoom(generation)) return;
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

  Future<int> getQualityLevel() async =>
      AppSettingsController.instance.qualityLevel.value;

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
    return Media(url, httpHeaders: playHeaders);
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

  Future<void> resetRoom(Site site, String roomId) async {
    if (_closing || (this.site == site && this.roomId == roomId)) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;
    final generation = ++_roomGeneration;
    _invalidatePlayback();
    _invalidateMessages();

    // 清除全部消息
    liveDanmaku.stop();

    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // Stop and subsequent open use the same native queue.
    try {
      await runPlayerCommand(() async {
        if (_isCurrentRoom(generation)) await player.stop();
      });
      if (!_isCurrentRoom(generation)) return;
      await loadData();
    } catch (error) {
      if (!_isCurrentRoom(generation)) return;
      errorMsg.value = '切换直播间失败，请刷新重试';
      showPlaybackFailure();
    }
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
    if (_closing) return;
    _closing = true;
    ++_roomGeneration;
    _invalidatePlayback();
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
