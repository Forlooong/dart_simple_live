import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';
import 'package:simple_live_tv_app/widgets/net_image.dart';

class AnchorCard extends StatefulWidget {
  final String siteId;
  final String face;
  final String name;
  final String roomId;
  final int liveStatus;
  final String? statusDescription;
  final bool autofocus;
  final Function()? onTap;
  final AppFocusNode? focusNode;
  const AnchorCard({
    required this.face,
    required this.siteId,
    required this.name,
    required this.liveStatus,
    required this.roomId,
    this.statusDescription,
    this.autofocus = false,
    this.focusNode,
    this.onTap,
    super.key,
  });

  @override
  State<AnchorCard> createState() => _AnchorCardState();
}

class _AnchorCardState extends State<AnchorCard> {
  final _ownedFocus = AppFocusNode();

  @override
  void dispose() {
    _ownedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final site = Sites.allSites[widget.siteId]!;
    final focusNode = widget.focusNode ?? _ownedFocus;
    final status =
        widget.statusDescription ??
        (widget.liveStatus == 2
            ? '直播中'
            : widget.liveStatus == 1
            ? '未开播'
            : '状态未知');
    return Obx(
      () => HighlightWidget(
        onTap:
            widget.onTap ??
            () {
              AppNavigator.toLiveRoomDetail(site: site, roomId: widget.roomId);
            },
        focusNode: focusNode,
        autofocus: widget.autofocus,
        borderRadius: AppStyle.radius16,
        color: Colors.white10,
        child: Stack(
          children: [
            Padding(
              padding: AppStyle.edgeInsetsA20,
              child: Row(
                mainAxisSize: MainAxisSize.max,
                children: [
                  NetImage(
                    widget.face,
                    width: 100.w,
                    height: 100.w,
                    borderRadius: 100.w,
                    cacheWidth: 100,
                  ),
                  AppStyle.hGap16,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          widget.name,
                          style: TextStyle(
                            fontSize: 36.w,
                            overflow: TextOverflow.ellipsis,
                            color: focusNode.isFoucsed.value
                                ? Colors.black
                                : Colors.white,
                          ),
                        ),
                        Text.rich(
                          TextSpan(
                            children: [
                              WidgetSpan(
                                child: Image.asset(site.logo, width: 32.w),
                              ),
                              TextSpan(text: " ${site.name} · $status"),
                            ],
                          ),
                          style: TextStyle(
                            fontSize: 24.w,
                            color: focusNode.isFoucsed.value
                                ? Colors.black
                                : Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (widget.liveStatus == 2)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding: AppStyle.edgeInsetsH16.copyWith(
                    top: 4.w,
                    bottom: 4.w,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xff1b5e20),
                    borderRadius: BorderRadius.only(
                      topRight: Radius.circular(12.w),
                      bottomLeft: Radius.circular(12.w),
                    ),
                  ),
                  child: Text(
                    "直播中",
                    style: TextStyle(fontSize: 24.w, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
