import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/db_service.dart';

import 'aggregate_search.dart';

class AppSearchController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late final TabController tabController;
  final searchMode = 0.obs;
  final searchController = TextEditingController();
  final sites = List<Site>.of(Sites.supportSites);
  late final aggregate = AggregateSearch({
    for (final site in sites) site.id: site.liveSite,
  }, localDouyinResults: _localDouyin);

  AppSearchController() {
    tabController = TabController(length: sites.length + 1, vsync: this);
    aggregate.setActive(true);
    tabController.addListener(_selectTab);
  }

  void _selectTab() {
    final index = tabController.index;
    aggregate.selectPlatform(index == 0 ? null : sites[index - 1].id);
  }

  Iterable<AggregateSearchResult> _localDouyin(String keyword) sync* {
    final term = keyword.toLowerCase();
    final url = Uri.tryParse(keyword);
    final linkedRoom =
        url?.host == 'live.douyin.com' && url?.pathSegments.length == 1
        ? url!.pathSegments.single
        : null;
    final db = DBService.instance;
    for (final (site, room, author, source) in [
      for (final item in db.followBox.values)
        (item.siteId, item.roomId, item.userName, '本机关注'),
      for (final item in db.historyBox.values)
        (item.siteId, item.roomId, item.userName, '观看历史'),
    ]) {
      if (site == 'douyin' &&
          RegExp(r'^\d{1,16}$').hasMatch(room) &&
          (author.toLowerCase().contains(term) ||
              room == term ||
              room == linkedRoom)) {
        yield (
          roomId: room,
          author: author,
          title: null,
          live: Sites.allSites[site]?.liveSite.peekRoomStatus(room)?.live,
          source: source,
        );
      }
    }
  }

  void onKeywordEdited(String value) {
    if (aggregate.keyword.isNotEmpty && value.trim() != aggregate.keyword) {
      aggregate.reset('', searchAnchors: searchMode.value == 1);
    }
  }

  void doSearch() => aggregate.reset(
    searchController.text,
    searchAnchors: searchMode.value == 1,
  );

  @override
  void onClose() {
    tabController.dispose();
    searchController.dispose();
    aggregate.dispose();
    super.onClose();
  }
}
