import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get_rx/src/rx_types/rx_types.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/sites.dart';

class SearchAnchorController extends BasePageController<LiveAnchorItemExt> {
  final String keyword;
  SearchAnchorController(this.keyword);
  var siteId = Constant.kBiliBili.obs;
  var site = Sites.allSites[Constant.kBiliBili]!;

  @override
  Duration get pageTimeout => const Duration(seconds: 20);

  bool get showDouyinWebSearch =>
      siteId.value == Constant.kDouyin && !loadding.value && list.isEmpty;

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
  Future<({List<LiveAnchorItemExt> items, bool hasMore})> getPage(
    int page,
    int pageSize, {
    bool retry = false,
  }) async {
    final requestedSite = site;
    final result = await requestedSite.liveSite.searchAnchors(
      keyword,
      page: page,
    );

    final items = result.items
        .map(
          (e) => LiveAnchorItemExt(
            roomId: e.roomId,
            site: requestedSite,
            profile: e.profile,
            accountId: e.accountId,
            avatar: e.avatar,
            liveStatus: e.liveStatus,
            statusKnown: e.statusKnown,
            roomTitle: e.roomTitle,
            userName: e.userName,
          ),
        )
        .toList();
    return (items: items, hasMore: result.hasMore);
  }

  @override
  void onClose() {
    scrollController.removeListener(scrollListener);
    super.onClose();
  }
}

class LiveAnchorItemExt extends LiveAnchorItem {
  LiveAnchorItemExt({
    required super.roomId,
    required this.site,
    required super.avatar,
    required super.liveStatus,
    required super.userName,
    super.profile,
    super.accountId,
    super.statusKnown,
    super.roomTitle,
  });

  final Site site;
  AppFocusNode focusNode = AppFocusNode();
}
