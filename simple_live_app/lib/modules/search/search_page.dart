import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/aggregate_search_view.dart';

class SearchPage extends GetView<AppSearchController> {
  const SearchPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: TextField(
            controller: controller.searchController,
            autofocus: true,
            onChanged: controller.onKeywordEdited,
            decoration: InputDecoration(
              hintText: "输入主播或直播间关键词",
              border: OutlineInputBorder(borderRadius: AppStyle.radius24),
              contentPadding: AppStyle.edgeInsetsH12,
              prefixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: "返回",
                    onPressed: Get.back,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Obx(
                    () => DropdownButton<int>(
                      underline: const SizedBox(),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text("房间")),
                        DropdownMenuItem(value: 1, child: Text("主播")),
                      ],
                      value: controller.searchMode.value,
                      onChanged: (e) {
                        controller.searchMode.value = e ?? 0;
                        controller.doSearch();
                      },
                    ),
                  ),
                  AppStyle.hGap8,
                ],
              ),
              suffixIcon: IconButton(
                tooltip: "搜索",
                onPressed: controller.doSearch,
                icon: const Icon(Icons.search),
              ),
            ),
            onSubmitted: (e) {
              controller.doSearch();
            },
          ),
          bottom: TabBar(
            controller: controller.tabController,
            padding: EdgeInsets.zero,
            tabAlignment: TabAlignment.start,
            tabs: [
              _platformTab(
                '全部平台',
                Builder(
                  builder: (context) => ColoredBox(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(
                      Icons.apps,
                      size: 19,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              for (final site in controller.sites)
                _platformTab(
                  site.name,
                  Image.asset(
                    site.logo,
                    fit: BoxFit.cover,
                    excludeFromSemantics: true,
                  ),
                ),
            ],
            labelPadding: AppStyle.edgeInsetsH20,
            isScrollable: true,
            indicatorSize: TabBarIndicatorSize.label,
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          controller: controller.tabController,
          children: [
            AggregateSearchView(controller.aggregate),
            for (final site in controller.sites)
              AggregateSearchView(controller.aggregate, platform: site.id),
          ],
        ),
      ),
    );
  }

  Tab _platformTab(String label, Widget icon) => Tab(
    child: Row(
      children: [
        ExcludeSemantics(
          child: ClipRRect(
            borderRadius: AppStyle.radius4,
            child: SizedBox.square(dimension: 24, child: icon),
          ),
        ),
        AppStyle.hGap8,
        Text(label),
      ],
    ),
  );
}
