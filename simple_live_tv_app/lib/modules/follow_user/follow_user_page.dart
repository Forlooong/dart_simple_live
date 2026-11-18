import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';
import 'package:simple_live_tv_app/widgets/card/anchor_card.dart';

class FollowUserPage extends StatefulWidget {
  const FollowUserPage({super.key});

  @override
  State<FollowUserPage> createState() => _FollowUserPageState();
}

class _FollowUserPageState extends State<FollowUserPage> {
  final backFocus = AppFocusNode();
  final refreshFocus = AppFocusNode();

  @override
  void dispose() {
    backFocus.dispose();
    refreshFocus.dispose();
    super.dispose();
  }

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
                focusNode: backFocus,
                iconData: Icons.arrow_back,
                text: "返回",
                autofocus: true,
                onTap: () {
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "我的关注",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AppStyle.hGap24,
              const Spacer(),
              HighlightButton(
                focusNode: refreshFocus,
                iconData: Icons.refresh,
                text: "刷新",
                onTap: () {
                  FollowUserService.instance.refreshData();
                },
              ),
              AppStyle.hGap48,
            ],
          ),
          AppStyle.vGap48,
          Expanded(
            child: Obx(() {
              final service = FollowUserService.instance;
              final items = service.list.toList();
              if (items.isEmpty)
                return Center(
                  child: Text(
                    service.updating.value ? '正在刷新关注' : '暂无关注',
                    style: AppStyle.titleStyleWhite,
                  ),
                );
              final indexes = {
                for (var i = 0; i < items.length; i++) items[i].id: i,
              };
              return FocusTraversalGroup(
                child: GridView.builder(
                  padding: AppStyle.edgeInsetsH48,
                  itemCount: items.length,
                  findChildIndexCallback: (key) =>
                      indexes[(key as ValueKey<String>).value],
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 48.w,
                    mainAxisSpacing: 40.w,
                    mainAxisExtent: 160.w,
                  ),
                  itemBuilder: (_, i) {
                    final item = items[i];
                    return KeyedSubtree(
                      key: ValueKey(item.id),
                      child: Obx(() {
                        final status = item.liveStatus.value;
                        final issue = item.statusIssue.value;
                        final date = item.lastStatusCheck;
                        final stale =
                            date != null &&
                            DateTime.now().difference(date) >=
                                const Duration(hours: 1);
                        final label = status == 2
                            ? '直播中'
                            : status == 1
                            ? '未开播'
                            : '状态未知';
                        return AnchorCard(
                          face: item.face,
                          name: item.userName,
                          siteId: item.siteId,
                          liveStatus: status,
                          statusDescription:
                              '$label${stale
                                  ? '（已过期）'
                                  : issue == null
                                  ? ''
                                  : '（更新失败）'}',
                          roomId: item.roomId,
                        );
                      }),
                    );
                  },
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
