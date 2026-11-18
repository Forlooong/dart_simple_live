import 'dart:async';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';

import 'aggregate_search.dart';

class AppSearchController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late TabController tabController;
  int index = 0;

  var searchMode = 0.obs;

  int get aggregateIndex => Sites.supportSites.length;
  final aggregate = AggregateSearch({
    for (final site in Sites.supportSites) site.id: site.liveSite,
  });

  AppSearchController() {
    tabController = TabController(length: aggregateIndex + 1, vsync: this);
    tabController.addListener(_selectTab);
  }

  void _selectTab() {
    final currentIndex = tabController.index;
    if (index == currentIndex) return;
    index = currentIndex;
    aggregate.setActive(index == aggregateIndex);
    if (index == aggregateIndex) return;
    final controller = Get.find<SearchListController>(
      tag: Sites.supportSites[index].id,
    );
    if (controller.list.isEmpty &&
        !controller.pageEmpty.value &&
        controller.keyword.isNotEmpty) {
      controller.refreshData();
    }
  }

  StreamSubscription<dynamic>? streamSubscription;

  TextEditingController searchController = TextEditingController();

  @override
  void onInit() {
    for (var site in Sites.supportSites) {
      // if (site.id == Constant.kDouyin) {
      //   Get.put(DouyinSearchController(site));
      // } else {
      Get.put(SearchListController(site), tag: site.id);
      //}
    }

    super.onInit();
  }

  void doSearch() {
    final keyword = searchController.text.trim();
    aggregate.reset(keyword, searchAnchors: searchMode.value == 1);
    for (final site in Sites.supportSites) {
      final controller = Get.find<SearchListController>(tag: site.id);
      controller.clear();
      controller.keyword = keyword;
      controller.searchMode.value = searchMode.value;
    }
    if (keyword.isEmpty || index == aggregateIndex) return;
    Get.find<SearchListController>(
      tag: Sites.supportSites[index].id,
    ).refreshData();
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    tabController.dispose();
    searchController.dispose();
    aggregate.dispose();
    super.onClose();
  }
}
