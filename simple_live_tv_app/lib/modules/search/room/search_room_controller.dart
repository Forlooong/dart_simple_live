import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get_rx/src/rx_types/rx_types.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/hot_live/hot_live_controller.dart';

class SearchRoomController extends BasePageController<LiveRoomItemExt> {
  final String keyword;
  SearchRoomController(this.keyword)
    : siteId =
          (DouyinSite.directSearchRoomId(keyword) != null
                  ? Constant.kDouyin
                  : Constant.kBiliBili)
              .obs {
    site = Sites.allSites[siteId.value]!;
  }
  final RxString siteId;
  late Site site;
  DouyinRoomSearch? _douyinSearch;
  final partialFailure = Rxn<CoreError>();
  final retryFocusNode = AppFocusNode();

  @override
  Duration get pageTimeout => const Duration(seconds: 20);

  bool get showDouyinWebSearch =>
      siteId.value == Constant.kDouyin &&
      !loadding.value &&
      (list.isEmpty || partialFailure.value != null);

  @override
  void onInit() {
    scrollController.addListener(scrollListener);
    refreshData();
    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.pixels >=
        (scrollController.position.maxScrollExtent - 100.w)) {
      loadData();
    }
  }

  void setSite(String id) {
    siteId.value = id;
    site = Sites.allSites[id]!;
    refreshData();
  }

  @override
  Future<void> refreshData() async {
    partialFailure.value = null;
    _douyinSearch = null;
    await super.refreshData();
  }

  Future<void> retrySearch() =>
      _douyinSearch == null ? refreshData() : loadData(retry: true);

  @override
  Future<({List<LiveRoomItemExt> items, bool hasMore})> getPage(
    int page,
    int pageSize, {
    bool retry = false,
  }) async {
    final requestedSite = site;
    final generation = pageGeneration;
    final provider = requestedSite.liveSite;
    final search =
        provider is DouyinSite && DouyinSite.directSearchRoomId(keyword) == null
        ? _douyinSearch ??= provider.createRoomSearch(keyword)
        : null;
    final result = search == null
        ? await provider.searchRooms(keyword, page: page)
        : await search.load(retry: retry);
    if (pageGeneration != generation) {
      return (items: <LiveRoomItemExt>[], hasMore: false);
    }

    final failure = result.partialFailure;
    if (search != null) {
      partialFailure.value = failure;
    } else if (failure != null) {
      partialFailure.value ??= failure;
    }
    if (list.isEmpty &&
        result.items.isEmpty &&
        failure != null &&
        !result.hasMore) {
      throw failure;
    }
    final seen = search == null
        ? null
        : {
            for (final room in list)
              room.roomId.isEmpty ? room.profile?.path : room.roomId,
          };
    final items = [
      for (final room in result.items)
        if (seen?.add(room.roomId.isEmpty ? room.profile?.path : room.roomId) ??
            true)
          LiveRoomItemExt(
            roomId: room.roomId,
            title: room.title.isEmpty ? room.userName : room.title,
            cover: room.cover,
            userName: room.userName,
            online: room.online,
            onlineKnown: room.onlineKnown,
            profile: room.profile,
            liveStatus: room.liveStatus,
            searchSite: requestedSite,
          ),
    ];
    return (items: items, hasMore: result.hasMore);
  }

  @override
  void onClose() {
    scrollController.removeListener(scrollListener);
    retryFocusNode.dispose();
    super.onClose();
  }
}
