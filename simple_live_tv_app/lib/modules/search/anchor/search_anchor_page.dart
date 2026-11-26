import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/search/anchor/search_anchor_controller.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/modules/search/douyin_search_fallback.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';
import 'package:simple_live_tv_app/widgets/card/anchor_card.dart';
import 'package:simple_live_tv_app/widgets/status/app_empty_widget.dart';
import 'package:simple_live_tv_app/widgets/status/app_error_widget.dart';
import 'package:url_launcher/url_launcher.dart';

class SearchAnchorPage extends GetView<SearchAnchorController> {
  const SearchAnchorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: Column(
        children: [
          AppStyle.vGap32,
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppStyle.hGap48,
              HighlightButton(
                focusNode: AppFocusNode(),
                iconData: Icons.arrow_back,
                text: "返回",
                //autofocus: true,
                onTap: () {
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "搜索：${controller.keyword}",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AppStyle.hGap24,
              const Spacer(),
              Obx(
                () => Visibility(
                  visible: controller.loadding.value,
                  child: SizedBox(
                    width: 48.w,
                    height: 48.w,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 4.w,
                    ),
                  ),
                ),
              ),
              AppStyle.hGap24,
              // HighlightButton(
              //   focusNode: AppFocusNode(),
              //   iconData: Icons.refresh,
              //   text: "刷新",
              //   onTap: () {
              //     controller.refreshData();
              //   },
              // ),
              AppStyle.hGap48,
            ],
          ),
          AppStyle.vGap24,
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 36.w,
            children: Sites.supportSites
                .map(
                  (e) => Obx(
                    () => HighlightButton(
                      icon: Image.asset(e.logo, width: 48.w, height: 48.w),
                      text: e.name,
                      selected: controller.siteId.value == e.id,
                      focusNode: AppFocusNode(),
                      onTap: () {
                        controller.setSite(e.id);
                      },
                    ),
                  ),
                )
                .toList(),
          ),
          AppStyle.vGap24,
          Obx(() {
            if (!controller.showDouyinWebSearch) {
              return const SizedBox.shrink();
            }
            return DouyinSearchFallback(
              keyword: controller.keyword,
              anchors: true,
            );
          }),
          Expanded(
            child: Obx(
              () => Stack(
                children: [
                  MasonryGridView.count(
                    padding: AppStyle.edgeInsetsA48,
                    itemCount: controller.list.length,
                    crossAxisCount: 3,
                    crossAxisSpacing: 48.w,
                    mainAxisSpacing: 40.w,
                    controller: controller.scrollController,
                    itemBuilder: (_, i) {
                      var item = controller.list[i];

                      if (i == 0) {
                        Future.delayed(Duration.zero, () {
                          if (controller.currentPage == 2 &&
                              identical(controller.list.firstOrNull, item)) {
                            item.focusNode.requestFocus();
                          }
                        });
                      }
                      return AnchorCard(
                        siteId: controller.siteId.value,
                        name: item.userName,
                        liveStatus: !item.statusKnown
                            ? 0
                            : item.liveStatus
                            ? 2
                            : 1,
                        face: item.avatar,
                        roomId: item.roomId,
                        focusNode: item.focusNode,
                        onTap: () {
                          if (item.roomId.isNotEmpty) {
                            AppNavigator.toLiveRoomDetail(
                              site: item.site,
                              roomId: item.roomId,
                            );
                            return;
                          }
                          final profile = item.profile;
                          if (profile != null) {
                            launchUrl(
                              profile,
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                      );
                    },
                  ),
                  Obx(
                    () => Visibility(
                      visible:
                          controller.list.isEmpty &&
                          !controller.loadding.value &&
                          !controller.pageError.value,
                      child: AppEmptyWidget(
                        onRefresh: () {
                          controller.refreshData();
                        },
                      ),
                    ),
                  ),
                  Obx(
                    () => Visibility(
                      visible:
                          controller.pageError.value &&
                          !controller.loadding.value,
                      child: AppErrorWidget(
                        errorMsg: controller.errorMsg.value,
                        onRefresh: () {
                          controller.refreshData();
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
