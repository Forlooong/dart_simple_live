// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/live_notification_service.dart';

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;
  final notificationUpdates = <String>{}.obs;
  bool _closed = false;

  /// 0:全部 1:直播中 2:未直播
  var filterMode = FollowUserTag(id: "0", tag: "全部", userId: []).obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "0", tag: "全部", userId: []),
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
  ].obs;

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;

  @override
  void onInit() {
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream = FollowService.instance.updatedListStream.listen((
      event,
    ) {
      updateTagList();
      filterData();
    });
    super.onInit();
  }

  @override
  Future refreshData() async {
    if (_closed) return;
    await FollowService.instance.loadData();
    if (_closed) return;
    updateTagList();
    await loadData();
  }

  // Follows are one reactive snapshot, not an append-only paginated feed.
  // A service event can arrive while BasePageController awaits getData; using
  // that pagination path would append the same rooms a second time.
  @override
  Future<void> loadData() async {
    if (_closed) return;
    currentPage = 1;
    filterData();
    pageLoadding.value = false;
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return Future.value([]);
    }
    if (filterMode.value.tag == "全部") {
      return FollowService.instance.followList.value;
    } else if (filterMode.value.tag == "直播中") {
      return FollowService.instance.liveList.value;
    } else if (filterMode.value.tag == "未开播") {
      return FollowService.instance.notLiveList.value;
    } else {
      FollowService.instance.filterDataByTag(filterMode.value);
      return FollowService.instance.curTagFollowList.value;
    }
  }

  void updateTagList() {
    userTagList.assignAll(FollowService.instance.followTagList);
    tagList.value = tagList.take(3).toList();
    for (var i in userTagList) {
      if (!tagList.contains(i)) {
        tagList.add(i);
      }
    }
  }

  void filterData() {
    if (_closed) return;
    if (filterMode.value.tag == "全部") {
      list.assignAll(FollowService.instance.followList.value);
    } else if (filterMode.value.tag == "直播中") {
      list.assignAll(FollowService.instance.liveList.value);
    } else if (filterMode.value.tag == "未开播") {
      list.assignAll(FollowService.instance.notLiveList.value);
    } else {
      FollowService.instance.filterDataByTag(filterMode.value);
      list.assignAll(FollowService.instance.curTagFollowList);
    }
    pageEmpty.value = list.isEmpty;
    pageError.value = false;
    canLoadMore.value = false;
  }

  void setFilterMode(FollowUserTag tag) {
    filterMode.value = tag;
    filterData();
  }

  Future<void> toggleNotification(FollowUser item) async {
    if (!notificationUpdates.add(item.id)) return;
    try {
      final enabled = await LiveNotificationService.instance.toggle(item);
      await FollowService.instance.loadData(updateStatus: false);
      SmartDialog.showToast(enabled ? '已开启开播提醒' : '已关闭开播提醒');
    } catch (error, stackTrace) {
      Log.e('更新开播提醒失败: $error', stackTrace);
      final message = exceptionToString(error).trim();
      SmartDialog.showToast(message.isEmpty ? '暂时无法更新开播提醒，请稍后重试' : message);
    } finally {
      notificationUpdates.remove(item.id);
    }
  }

  Future<void> removeItem(FollowUser item) async {
    var result = await Utils.showAlertDialog(
      "确定要取消关注${item.userName}吗?",
      title: "取消关注",
    );
    if (!result) {
      return;
    }
    await DBService.instance.deleteFollow(item.id);
    await refreshData();
  }

  Future<void> updateItem(FollowUser item) =>
      FollowService.instance.addFollow(item);

  // 修改item的标签
  Future<void> setItemTag(FollowUser item, FollowUserTag targetTag) async {
    try {
      await DBService.instance.moveFollow(
        item.id,
        targetTag.tag == '全部' ? null : targetTag.id,
      );
      await FollowService.instance.loadData(updateStatus: false);
    } catch (error) {
      SmartDialog.showToast("标签更新失败，请重试");
    }
  }

  Future<void> removeTag(FollowUserTag tag) async {
    try {
      await FollowService.instance.delFollowUserTag(tag);
      await FollowService.instance.loadData(updateStatus: false);
      updateTagList();
    } catch (error) {
      SmartDialog.showToast("标签删除失败，请重试");
    }
  }

  Future<void> addTag(String tag) async {
    try {
      await FollowService.instance.addFollowUserTag(tag);
      if (!_closed) updateTagList();
    } catch (error) {
      SmartDialog.showToast("标签添加失败，请重试");
    }
  }

  Future<void> updateTag(FollowUserTag followUserTag) async {
    if (followUserTag.tag == '全部') {
      return;
    }
    await FollowService.instance.updateFollowUserTag(followUserTag);
  }

  Future<void> updateTagName(
    FollowUserTag followUserTag,
    String newTagName,
  ) async {
    // 未操作
    if (followUserTag.tag == newTagName) {
      return;
    }
    // 避免重名
    if (tagList.any((item) => item.tag == newTagName)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    final FollowUserTag newTag = followUserTag.copyWith(tag: newTagName);
    try {
      await DBService.instance.renameFollowTag(newTag.id, newTag.tag);
      if (!DBService.instance.getFollowTagExist(newTag.id)) return;
      await FollowService.instance.loadData(updateStatus: false);
      SmartDialog.showToast("标签名修改成功");
      updateTagList();
    } catch (error) {
      SmartDialog.showToast("标签更新失败，请重试");
    }
  }

  // 调整标签顺序
  Future<void> updateTagOrder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1; // 处理索引调整
    final item = userTagList.removeAt(oldIndex);
    userTagList.insert(newIndex, item);
    tagList.value = tagList.take(3).toList();
    tagList.addAll(userTagList);
    try {
      await FollowService.instance.updateFollowTagOrder(userTagList.toList());
    } catch (error) {
      if (!_closed) {
        updateTagList();
        SmartDialog.showToast("标签排序保存失败，请重试");
      }
    }
  }

  @override
  void onClose() {
    _closed = true;
    onUpdatedIndexedStream?.cancel();
    onUpdatedListStream?.cancel();
    super.onClose();
  }
}
