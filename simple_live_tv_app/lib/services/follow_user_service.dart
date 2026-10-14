import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/services/db_service.dart';

class FollowUserService extends BasePageController<FollowUser>
    with WidgetsBindingObserver {
  FollowUserService({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  static FollowUserService get instance => Get.find<FollowUserService>();
  StreamSubscription<dynamic>? subscription;
  RxList<FollowUser> livingList = RxList<FollowUser>();
  Timer? updateTimer;
  bool needUpdate = true;
  var updatedCount = 0;
  var updating = false.obs;
  final _refreshQueue = StatusRefreshQueue();
  Future<void>? _refreshFuture;
  Worker? _concurrencyWorker;
  DateTime? _nextRefresh;
  bool _foreground = true;
  bool _closed = false;
  int _watchers = 0;

  void beginWatching() {
    _watchers++;
    _refreshQueue.concurrency = _concurrency;
  }

  void endWatching() {
    if (_watchers > 0) _watchers--;
    _refreshQueue.concurrency = _concurrency;
  }

  int get _concurrency {
    final setting =
        AppSettingsController.instance.updateFollowThreadCount.value;
    final configured = setting == 0 ? 4 : setting.clamp(1, 8);
    return _watchers > 0 ? configured.clamp(1, 2) : configured;
  }

  Duration get _refreshInterval => Duration(
        minutes: AppSettingsController.instance.autoUpdateFollowDuration.value
            .clamp(1, 1440),
      );

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (_) {
      list.assignAll(DBService.instance.getFollowList());
      sortList();
    });
    _concurrencyWorker = ever(
      AppSettingsController.instance.updateFollowThreadCount,
      (_) {
        _refreshQueue.concurrency = _concurrency;
      },
    );
    if (list.isEmpty) unawaited(refreshData());
    initTimer();
    super.onInit();
  }

  void initTimer() {
    updateTimer?.cancel();
    _nextRefresh = _now().add(_refreshInterval);
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    updateTimer?.cancel();
    if (_closed ||
        !_foreground ||
        !AppSettingsController.instance.autoUpdateFollowEnable.value) {
      return;
    }
    final delay = (_nextRefresh ?? _now()).difference(_now());
    updateTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _nextRefresh = _now().add(_refreshInterval);
      unawaited(refreshData(automatic: true));
      _scheduleRefresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    final wasForeground = _foreground;
    _foreground = resumed;
    if (!resumed) {
      updateTimer?.cancel();
      if (_refreshQueue.isRunning) _nextRefresh = _now();
      _refreshQueue.pause();
    } else if (!wasForeground) {
      unawaited(
        (_refreshFuture ?? Future<void>.value()).whenComplete(_scheduleRefresh),
      );
    }
  }

  @override
  Future<void> refreshData({bool automatic = false}) {
    if (_closed || (automatic && !_foreground)) return Future.value();
    if (_refreshFuture != null) return _refreshFuture!;
    currentPage = 2;
    list.assignAll(DBService.instance.getFollowList());
    pageEmpty.value = list.isEmpty;
    canLoadMore.value = false;
    sortList();
    if (!needUpdate) {
      needUpdate = true;
      return Future.value();
    }
    return startUpdateStatus(list.toList(), automatic: automatic);
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async =>
      page > 1 ? [] : DBService.instance.getFollowList();

  void sortList() {
    list.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    updateLivingList();
  }

  void updateLivingList() {
    livingList.assignAll(list.where((x) => x.liveStatus.value == 2));
  }

  Future<void> startUpdateStatus(
    List<FollowUser> followList, {
    bool automatic = false,
  }) {
    if (_refreshFuture != null) return _refreshFuture!;
    updatedCount = 0;
    updating.value = true;
    var completed = 0;
    final snapshot = followList.toList();
    final configurations = {
      for (final item in snapshot)
        item.siteId:
            Sites.allSites[item.siteId]?.liveSite.statusConfigurationVersion,
    };
    _refreshQueue.concurrency = _concurrency;
    final future = _refreshQueue.run(
      snapshot.map(
        (item) => () async {
          if (_closed) return;
          await updateLiveStatus(
            item,
            automatic: automatic,
            configurationVersion: configurations[item.siteId],
          );
          if (!_closed) updatedCount = ++completed;
        },
      ),
    );
    _refreshFuture = future.whenComplete(() {
      _refreshFuture = null;
      if (!_closed) {
        sortList();
        updating.value = false;
      }
    });
    return _refreshFuture!;
  }

  Future<void> updateLiveStatus(
    FollowUser item, {
    bool automatic = false,
    int? configurationVersion,
  }) async {
    final site = Sites.allSites[item.siteId]?.liveSite;
    if (site == null) return;
    final version = configurationVersion ?? site.statusConfigurationVersion;
    bool current() =>
        !_closed &&
        site.statusConfigurationVersion == version &&
        list.any((room) => identical(room, item)) &&
        identical(DBService.instance.followBox.get(item.id), item);
    if (!current()) return;
    try {
      final status = await site.getRoomStatusCached(
        roomId: item.roomId,
        automatic: automatic,
      );
      if (current()) item.liveStatus.value = status.live ? 2 : 1;
    } catch (error) {
      Log.logPrint(error);
      if (current()) item.liveStatus.value = 0;
    }
  }

  void removeItem(FollowUser item, {bool refresh = true}) async {
    final result = await Utils.showAlertDialog(
      "确定要取消关注${item.userName}吗?",
      title: "取消关注",
    );
    if (!result) return;
    await DBService.instance.followBox.delete(item.id);
    list.remove(item);
    livingList.remove(item);
    if (refresh) await refreshData();
  }

  @override
  void onClose() {
    _closed = true;
    _refreshQueue.pause();
    _concurrencyWorker?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    updateTimer?.cancel();
    subscription?.cancel();
    super.onClose();
  }
}
