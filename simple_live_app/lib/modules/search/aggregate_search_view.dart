import 'package:flutter/material.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'aggregate_search.dart';

class AggregateSearchView extends StatefulWidget {
  const AggregateSearchView(this.search, {super.key});
  final AggregateSearch search;

  @override
  State<AggregateSearchView> createState() => _AggregateSearchViewState();
}

class _AggregateSearchViewState extends State<AggregateSearchView> {
  bool liveOnly = false;

  String _failure(CoreErrorKind error) => switch (error) {
    CoreErrorKind.rateLimited => '平台限流，请稍后重试',
    CoreErrorKind.authRequired => '请检查平台登录状态',
    CoreErrorKind.timeout => '请求超时',
    CoreErrorKind.schemaChanged => '平台响应格式变化',
    _ => '暂时无法搜索',
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.search,
    builder: (context, child) {
      if (widget.search.keyword.isEmpty)
        return const Center(child: Text('输入关键词开始搜索'));
      final sections = <Widget>[
        SwitchListTile(
          title: const Text('仅直播中'),
          value: liveOnly,
          onChanged: (enabled) => setState(() => liveOnly = enabled),
        ),
      ];
      for (final site in Sites.supportSites) {
        final id = site.id;
        final result = widget.search.platforms[id];
        if (result == null) continue;
        final unknown = result.results.values
            .where((item) => item.live == null)
            .length;
        final matches = result.results.values
            .where((item) => !liveOnly || item.live == true)
            .toList();
        sections.addAll([
          const Divider(),
          ListTile(
            leading: Image.asset(
              site.logo,
              width: 24,
              excludeFromSemantics: true,
            ),
            title: Semantics(header: true, child: Text(site.name)),
          ),
          if (!widget.search.supports(id))
            const ListTile(title: Text('当前支持搜索直播间'))
          else ...[
            if (liveOnly && unknown > 0)
              ListTile(title: Text('$unknown 条结果状态未知')),
            for (final item in matches)
              ListTile(
                key: ValueKey((id, item.roomId)),
                title: Text(
                  item.title?.isNotEmpty == true ? item.title! : item.author,
                ),
                subtitle: Text(
                  [
                    if (item.title?.isNotEmpty == true) item.author,
                    item.live == true
                        ? '直播中'
                        : item.live == false
                        ? '未开播'
                        : '状态未知',
                  ].join(' · '),
                ),
                onTap: () => AppNavigator.toLiveRoomDetail(
                  site: site,
                  roomId: item.roomId,
                ),
              ),
            if (result.loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(semanticsLabel: '正在加载平台结果'),
              )
            else if (result.failure != null)
              ListTile(
                title: Text(_failure(result.failure!)),
                trailing: TextButton(
                  onPressed: () => widget.search.load(id),
                  child: const Text('重试'),
                ),
              )
            else ...[
              if (matches.isEmpty)
                ListTile(title: Text(liveOnly ? '暂无已确认开播的结果' : '没有搜索结果')),
              if (result.nextPage > 1 && result.hasMore)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => widget.search.load(id),
                    child: Text('加载更多${site.name}结果'),
                  ),
                ),
            ],
          ],
        ]);
      }
      return FocusTraversalGroup(child: ListView(children: sections));
    },
  );
}
