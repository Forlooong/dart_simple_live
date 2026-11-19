import 'package:flutter/material.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'aggregate_search.dart';

class AggregateSearchView extends StatefulWidget {
  const AggregateSearchView(this.search, {this.platform, super.key});
  final AggregateSearch search;
  final String? platform;

  @override
  State<AggregateSearchView> createState() => _AggregateSearchViewState();
}

class _AggregateSearchViewState extends State<AggregateSearchView> {
  bool liveOnly = false;
  String? filter;

  String _failure(CoreErrorKind error) => switch (error) {
    CoreErrorKind.rateLimited => '平台限流，请稍后重试',
    CoreErrorKind.authRequired => '请检查平台登录状态',
    CoreErrorKind.timeout => '请求超时',
    CoreErrorKind.schemaChanged => '平台响应格式变化',
    _ => '暂时无法搜索',
  };

  Future<void> _open(Uri url) async {
    if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开抖音页面')));
    }
  }

  Future<void> _openOfficialSearch({required bool anchors}) => _open(
    Uri.https('www.douyin.com', '/search/${widget.search.keyword}', {
      'type': anchors ? 'user' : 'live',
    }),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.search,
    builder: (context, child) {
      final search = widget.search;
      if (search.keyword.isEmpty) {
        return const Center(child: Text('输入关键词开始搜索'));
      }
      final id = widget.platform ?? filter;
      final sites = search.sites.keys.where((site) => id == null || site == id);
      final rows = search.ordered.where((row) => id == null || row.$1 == id);
      AggregateSearchResult itemFor((String, String) row) =>
          search.platforms[row.$1]!.results[row.$2]!;
      final unknown = rows.where((row) => itemFor(row).live == null).length;
      final matches = rows.where(
        (row) => !liveOnly || itemFor(row).live == true,
      );
      return FocusTraversalGroup(
        child: CustomScrollView(
          key: PageStorageKey(('search', widget.platform)),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  if (widget.platform == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: DropdownButtonFormField<String>(
                        initialValue: filter ?? '',
                        decoration: const InputDecoration(labelText: '平台'),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('全部平台'),
                          ),
                          for (final site in search.sites.keys)
                            DropdownMenuItem(
                              value: site,
                              child: Text(Sites.allSites[site]!.name),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => filter = value == '' ? null : value),
                      ),
                    ),
                  SwitchListTile(
                    title: const Text('仅直播中'),
                    value: liveOnly,
                    onChanged: (value) => setState(() => liveOnly = value),
                  ),
                  if (liveOnly && unknown > 0)
                    ListTile(title: Text('$unknown 条结果状态未知')),
                ],
              ),
            ),
            SliverList(
              delegate: SliverChildListDelegate([
                for (final row in matches)
                  _result(Sites.allSites[row.$1]!, itemFor(row), ValueKey(row)),
              ]),
            ),
            SliverToBoxAdapter(
              child: Column(
                children: [
                  if (matches.isEmpty &&
                      sites.any(search.supportsRemote) &&
                      sites.every(
                        (id) =>
                            search.platforms[id]?.loading != true &&
                            search.platforms[id]?.failure == null,
                      ))
                    ListTile(title: Text(liveOnly ? '暂无已确认开播的结果' : '没有匹配结果')),
                  for (final id in sites)
                    if (search.platforms[id] case final result?)
                      _actions(id, result),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _result(Site site, AggregateSearchResult item, Key key) {
    final hasTitle = item.title?.isNotEmpty == true;
    final status = switch (item.live) {
      true => '直播中',
      false => '未开播',
      null => '状态未知',
    };
    return ListTile(
      key: key,
      leading: Image.asset(
        site.logo,
        width: 24,
        height: 24,
        excludeFromSemantics: true,
      ),
      title: Text(
        hasTitle && !widget.search.anchors ? item.title! : item.author,
      ),
      subtitle: Text(
        [
          site.name,
          if (hasTitle) widget.search.anchors ? item.title! : item.author,
          status,
          if (item.source != null) item.source!,
        ].join(' · '),
      ),
      onTap: () =>
          AppNavigator.toLiveRoomDetail(site: site, roomId: item.roomId),
    );
  }

  Widget _actions(String id, PlatformSearchResults result) {
    final name = Sites.allSites[id]!.name;
    if (!widget.search.supportsRemote(id)) {
      return ListTile(
        title: const Text('抖音主播搜索可前往官方页面'),
        trailing: TextButton(
          onPressed: () => _openOfficialSearch(anchors: true),
          child: const Text('去抖音搜索'),
        ),
      );
    }
    if (result.loading) {
      return ListTile(
        title: Text('正在加载$name'),
        subtitle: const LinearProgressIndicator(),
      );
    }
    if (result.failure case final failure?) {
      return ListTile(
        title: Text('$name · ${_failure(failure)}'),
        trailing: TextButton(
          onPressed: () => widget.search.load(id),
          child: const Text('重试'),
        ),
        subtitle: id == 'douyin'
            ? Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _openOfficialSearch(anchors: false),
                  child: const Text('去抖音搜索'),
                ),
              )
            : null,
      );
    }
    if (result.hasMore && result.nextPage > 1) {
      return TextButton(
        onPressed: () => widget.search.load(id),
        child: Text('加载更多$name结果'),
      );
    }
    return const SizedBox.shrink();
  }
}
