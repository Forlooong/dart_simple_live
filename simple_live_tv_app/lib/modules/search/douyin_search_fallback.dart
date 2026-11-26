import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';
import 'package:url_launcher/url_launcher.dart';

class DouyinSearchFallback extends StatefulWidget {
  const DouyinSearchFallback({
    required this.keyword,
    required this.anchors,
    super.key,
  });

  final String keyword;
  final bool anchors;

  @override
  State<DouyinSearchFallback> createState() => _DouyinSearchFallbackState();
}

class _DouyinSearchFallbackState extends State<DouyinSearchFallback> {
  final _focusNode = AppFocusNode();

  Future<void> _openSearch() async {
    try {
      if (await launchUrl(
        DouyinSite.webSearchUri(widget.keyword, anchors: widget.anchors),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on Exception {
      // Some TV devices cannot open web links.
    }
    if (mounted) {
      SmartDialog.showToast('无法打开浏览器，可在手机抖音搜索并复制直播间直链');
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: HighlightButton(
      text: '去抖音搜索',
      iconData: Icons.open_in_browser,
      focusNode: _focusNode,
      onTap: _openSearch,
    ),
  );

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }
}
