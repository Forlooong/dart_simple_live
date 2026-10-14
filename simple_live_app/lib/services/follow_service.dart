import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FollowService extends GetxService with WidgetsBindingObserver {
  FollowService({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 已经更新状态的数量
  var updatedCount = 0;

  /// 是否正在更新
  var updating = false.obs;

  Timer? updateTimer;
  final _refreshQueue = StatusRefreshQueue();
  Future<void>? _refreshFuture;
  Worker? _concurrencyWorker;
  DateTime? _nextRefresh;
  int _watchers = 0;
  int _generation = 0;
  bool _foreground = true;
  bool _closed = false;

  void beginWatching() {
    _watchers++;
    _refreshQueue.concurrency = getOptimalConcurrency();
  }

  void endWatching() {
    if (_watchers > 0) _watchers--;
    _refreshQueue.concurrency = getOptimalConcurrency();
  }

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData(updateStatus: false);
    });
    _concurrencyWorker =
        ever(AppSettingsController.instance.updateFollowThreadCount, (_) {
      _refreshQueue.concurrency = getOptimalConcurrency();
    });
    initTimer();
    super.onInit();
  }

  // 添加标签
  Future<void> addFollowUserTag(String tag) async {
    // 判断待添加tag是否已存在，存在则return
    if (followTagList.any((item) => item.tag == tag)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    FollowUserTag item = await DBService.instance.addFollowTag(tag);
    followTagList.add(item);
  }

  // 删除标签
  Future<void> delFollowUserTag(FollowUserTag tag) async {
    followTagList.remove(tag);
    await DBService.instance.deleteFollowTag(tag.id);
  }

  // 获取用户自定义标签列表
  void getAllTagList() {
    var list = DBService.instance.getFollowTagList();
    followTagList.assignAll(list);
  }

  // 修改标签
  void updateFollowUserTag(FollowUserTag tag) {
    DBService.instance.updateFollowTag(tag);
    // 查找并修改
    var index = followTagList.indexWhere((oTag) => oTag.id == tag.id);
    followTagList[index] = tag;
  }

  // 根据标签筛选数据
  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.clear();
    // 用一个新的列表来存储需要删除的 userId
    List<String> toRemove = [];
    for (var id in tag.userId) {
      if (followList.any((x) => x.id == id)) {
        // 找到对应的 followUser 添加到 curTagFollowList
        curTagFollowList.add(followList.firstWhere((x) => x.id == id));
      } else {
        // 标记要删除的 id
        toRemove.add(id);
      }
    }
    // 双向确认用户取消关注后标签内是否还有该用户
    // 在遍历结束后统一移除不在 followList 中的 id
    tag.userId.removeWhere((id) => toRemove.contains(id));
    // 更新数据库
    if (toRemove.isNotEmpty) {
      DBService.instance.updateFollowTag(tag);
    }
    // 标签内排序
    curTagFollowList.sort(
      (a, b) => b.liveStatus.value.compareTo(a.liveStatus.value),
    );
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
  }

  void initTimer() {
    updateTimer?.cancel();
    _nextRefresh = _now().add(_refreshInterval);
    _scheduleRefresh();
  }

  Duration get _refreshInterval => Duration(
      minutes: AppSettingsController.instance.autoUpdateFollowDuration.value
          .clamp(1, 1440));

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
      unawaited(loadData(automatic: true));
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
      // Join the draining round before scheduling the one due foreground refresh.
      unawaited((_refreshFuture ?? Future<void>.value())
          .whenComplete(_scheduleRefresh));
    }
  }

  Future<void> loadData({bool updateStatus = true, bool automatic = false}) {
    if (_closed) return Future.value();
    if (updateStatus && _refreshFuture != null) return _refreshFuture!;
    final list = DBService.instance.getFollowList();
    getAllTagList();
    followList.assignAll(list);
    filterData();
    if (!updateStatus || (automatic && !_foreground)) return Future.value();
    return startUpdateStatus(automatic: automatic);
  }

  /// Network concurrency is independent of CPU count and lower during playback.
  int getOptimalConcurrency() {
    final userSetting =
        AppSettingsController.instance.updateFollowThreadCount.value;
    final configured = userSetting == 0 ? 4 : userSetting.clamp(1, 8);
    return _watchers > 0 ? configured.clamp(1, 2) : configured;
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> interleaveByPlatform(List<FollowUser> list) {
    // 按平台分组
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    // 交错处理
    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  Future<void> startUpdateStatus({bool automatic = false}) {
    if (_refreshFuture != null) return _refreshFuture!;
    updatedCount = 0;
    updating.value = true;
    final generation = _generation;
    var completed = 0;
    final snapshot = interleaveByPlatform(followList.toList());
    final configurations = {
      for (final item in snapshot)
        item.siteId:
            Sites.allSites[item.siteId]?.liveSite.statusConfigurationVersion
    };
    _refreshQueue.concurrency = getOptimalConcurrency();
    final future = _refreshQueue.run(snapshot.map((item) => () async {
          if (_closed || generation != _generation) return;
          await updateLiveStatus(item,
              automatic: automatic,
              configurationVersion: configurations[item.siteId]);
          if (!_closed && generation == _generation) updatedCount = ++completed;
        }));
    _refreshFuture = future.whenComplete(() {
      _refreshFuture = null;
      if (!_closed && generation == _generation) {
        filterData();
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
        followList.any((room) => identical(room, item)) &&
        identical(DBService.instance.followBox.get(item.id), item);
    if (!current()) return;
    try {
      final status = await site.getRoomStatusCached(
          roomId: item.roomId, automatic: automatic);
      if (!current()) return;
      item.liveStatus.value = status.live ? 2 : 1;
      item.liveStartTime = status.live ? status.showTime : null;
    } catch (e) {
      Log.logPrint(e);
      if (!current()) return;
      item.liveStatus.value = 0;
      item.liveStartTime = null;
    }
  }

  void filterData() {
    followList.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    notLiveList.assignAll(followList.where((x) => x.liveStatus.value == 1));
    _updatedListController.add(0);
  }

  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }

    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }

      var dir = "";
      if (Platform.isIOS) {
        dir = (await getApplicationDocumentsDirectory()).path;
      } else {
        dir = await FilePicker.platform.getDirectoryPath() ?? "";
      }

      if (dir.isEmpty) {
        return;
      }
      var jsonFile = File(
          '$dir/SimpleLive_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
      var jsonText = generateJson();
      await jsonFile.writeAsString(jsonText);
      SmartDialog.showToast("已导出关注列表");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }
      var file = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败:$e");
    } finally {
      loadData();
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: const Text("导出为文本"),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: const Text("复制"),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: const Text("从文本导入"),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: "请输入内容",
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: const Text("粘贴"),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("内容为空");
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功");
                Get.back();
                loadData();
              } catch (e) {
                SmartDialog.showToast("导入失败，请检查内容是否正确");
              }
            },
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    var data = followList.map((item) => item.toJson()).toList();
    return jsonEncode(data);
  }

  Future inputJson(String content) async {
    var data = jsonDecode(content);

    for (var item in data) {
      var follow = FollowUser.fromJson(
        item,
        existing: DBService.instance.followBox.get(item['id']),
      );
      // 导入关注列表同时导入标签列表 此方法可优化为所有导入逻辑
      if (follow.tag != "全部") {
        // logic: 尝试添加，存在则返回已存在的对象
        var tag = await DBService.instance.addFollowTag(follow.tag);
        // 更新tag
        tag.userId.addIf(!tag.userId.contains(follow.id), follow.id);
        await DBService.instance.updateFollowTag(tag);
      }
      await DBService.instance.addFollow(follow);
    }
  }

  @override
  void onClose() {
    _closed = true;
    _generation++;
    _refreshQueue.pause();
    _concurrencyWorker?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    updateTimer?.cancel();
    subscription?.cancel();
    _updatedListController.close();
    super.onClose();
  }
}
