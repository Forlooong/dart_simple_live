import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/net_image.dart';
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
  bool _liveOnly = false;
  String? _platformFilter;

  AggregateSearch get _search => widget.search;

  String _failure(String id, CoreErrorKind error) => switch (error) {
    CoreErrorKind.rateLimited => '平台限流，请稍后重试',
    CoreErrorKind.authRequired =>
      id == 'douyin' ? '请在设置中填写抖音 Cookie 后重试' : '请检查平台登录状态',
    CoreErrorKind.timeout => '请求超时，可以重试',
    CoreErrorKind.schemaChanged => '平台响应格式变化',
    _ => '暂时无法搜索',
  };

  Future<void> _open(Uri url) async {
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      // Platform launch failures use the same feedback as a missing handler.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开抖音页面')));
  }

  void _openDouyinSearch() {
    _open(douyinWebSearchUri(_search.keyword, anchors: _search.anchors));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _search,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final inset = ((constraints.maxWidth - 840) / 2)
            .clamp(16.0, double.infinity)
            .toDouble();
        return FocusTraversalGroup(
          child: CustomScrollView(
            key: PageStorageKey(('search', widget.platform)),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 16, inset, 24),
                sliver: SliverMainAxisGroup(
                  slivers: _search.keyword.isEmpty
                      ? [
                          const SliverToBoxAdapter(
                            child: _SearchMessage(
                              icon: Icons.search_rounded,
                              title: '搜索直播间或主播',
                              description: '输入关键词开始搜索，也可以粘贴抖音直播间链接。',
                            ),
                          ),
                        ]
                      : _results(context, compact: constraints.maxWidth < 400),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  List<Widget> _results(BuildContext context, {required bool compact}) {
    final id = widget.platform ?? _platformFilter;
    final platforms = _search.platforms.entries
        .where((entry) => id == null || entry.key == id)
        .toList();
    final rows = _search.ordered
        .where((row) => id == null || row.$1 == id)
        .toList();
    AggregateSearchResult itemFor((String, String) row) =>
        _search.platforms[row.$1]!.results[row.$2]!;
    final visible = _liveOnly
        ? rows.where((row) => itemFor(row).live == true).toList()
        : rows;
    final unknown = _liveOnly
        ? rows.where((row) => itemFor(row).live == null).length
        : 0;
    final loading = platforms.any((entry) => entry.value.loading);
    final failures = platforms
        .where((entry) => !entry.value.loading && entry.value.failure != null)
        .toList();
    final hasDouyinFallback = platforms.any(
      (entry) =>
          entry.key == 'douyin' &&
          !entry.value.loading &&
          entry.value.failure == null &&
          entry.value.results.isEmpty,
    );
    final more = platforms.where(
      (entry) =>
          !entry.value.loading &&
          entry.value.hasMore &&
          entry.value.nextPage > 1,
    );
    final theme = Theme.of(context);
    final label = _search.anchors ? '主播' : '直播间';
    final hasFilter = _liveOnly || _platformFilter != null;
    return [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _filters(compact: compact),
            AppStyle.vGap24,
            Text(
              '搜索结果',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (visible.isNotEmpty || loading) ...[
              AppStyle.vGap4,
              Semantics(
                liveRegion: true,
                child: Text(
                  visible.isEmpty ? '正在搜索…' : '已显示 ${visible.length} 条$label结果',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            if (unknown > 0) ...[
              AppStyle.vGap4,
              Text(
                '已隐藏 $unknown 条状态未知的结果',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (loading) ...[
              AppStyle.vGap12,
              const LinearProgressIndicator(semanticsLabel: '正在加载搜索结果'),
            ],
            for (final entry in failures) ...[
              AppStyle.vGap12,
              _platformFailure(entry.key, entry.value.failure!),
            ],
            AppStyle.vGap12,
          ],
        ),
      ),
      if (visible.isEmpty && !loading && (failures.isEmpty || rows.isNotEmpty))
        SliverToBoxAdapter(
          child: _SearchMessage(
            icon: _liveOnly
                ? Icons.live_tv_outlined
                : Icons.search_off_outlined,
            title: _liveOnly ? '暂无已确认开播的结果' : '没有匹配结果',
            description: _liveOnly
                ? '关闭「仅直播中」可查看未开播或状态未知的结果。'
                : hasFilter
                ? '试试清除筛选或更换关键词。'
                : '试试更短的关键词，或切换直播间和主播搜索。',
            action: hasFilter
                ? TextButton(
                    onPressed: () => setState(() {
                      _liveOnly = false;
                      _platformFilter = null;
                    }),
                    child: const Text('清除筛选'),
                  )
                : null,
          ),
        ),
      SliverList.builder(
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final row = visible[index];
          final item = itemFor(row);
          final site = Sites.allSites[row.$1]!;
          return _SearchResultTile(
            key: ValueKey(row),
            site: site,
            item: item,
            anchors: _search.anchors,
            compact: compact,
            onTap: item.roomId.isNotEmpty
                ? () => AppNavigator.toLiveRoomDetail(
                    site: site,
                    roomId: item.roomId,
                  )
                : item.profile == null
                ? null
                : () => _open(item.profile!),
          );
        },
      ),
      if (more.isNotEmpty || hasDouyinFallback)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in more)
                  OutlinedButton.icon(
                    onPressed: () => _search.load(entry.key),
                    icon: const Icon(Icons.expand_more_rounded),
                    label: Text('加载更多${Sites.allSites[entry.key]!.name}结果'),
                  ),
                if (hasDouyinFallback)
                  TextButton.icon(
                    onPressed: _openDouyinSearch,
                    icon: const Icon(Icons.open_in_new, size: 17),
                    label: const Text('去抖音搜索'),
                  ),
              ],
            ),
          ),
        ),
    ];
  }

  Widget _filters({required bool compact}) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (widget.platform == null && compact)
        PopupMenuButton<String>(
          tooltip: '筛选平台',
          initialValue: _platformFilter ?? '',
          onSelected: (value) => setState(() {
            _platformFilter = value.isEmpty ? null : value;
          }),
          itemBuilder: (_) => [
            const PopupMenuItem(value: '', child: Text('不限平台')),
            for (final id in _search.sites.keys)
              PopupMenuItem(value: id, child: Text(Sites.allSites[id]!.name)),
          ],
          child: Chip(
            label: Text(Sites.allSites[_platformFilter]?.name ?? '不限平台'),
            avatar: const Icon(Icons.arrow_drop_down_rounded, size: 18),
            backgroundColor: _platformFilter == null
                ? null
                : Theme.of(context).colorScheme.secondaryContainer,
          ),
        ),
      if (widget.platform == null && !compact) ...[
        ChoiceChip(
          label: const Text('不限平台'),
          selected: _platformFilter == null,
          onSelected: (_) => setState(() => _platformFilter = null),
        ),
        for (final id in _search.sites.keys)
          ChoiceChip(
            label: Text(Sites.allSites[id]!.name),
            selected: _platformFilter == id,
            onSelected: (selected) => setState(() {
              _platformFilter = selected ? id : null;
            }),
          ),
      ],
      FilterChip(
        label: const Text('仅直播中'),
        selected: _liveOnly,
        onSelected: (selected) => setState(() => _liveOnly = selected),
      ),
    ],
  );

  Widget _platformFailure(String id, CoreErrorKind failure) {
    final site = Sites.allSites[id]!;
    return _SearchMessage(
      icon: Icons.info_outline_rounded,
      title: '${site.name}结果可能不完整',
      description: _failure(id, failure),
      action: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton.icon(
            onPressed: () => _search.load(id, retry: true),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
          if (id == 'douyin')
            TextButton.icon(
              onPressed: _openDouyinSearch,
              icon: const Icon(Icons.open_in_new, size: 17),
              label: const Text('去抖音搜索'),
            ),
        ],
      ),
    );
  }
}

class _SearchMessage extends StatelessWidget {
  const _SearchMessage({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(icon, size: 22, color: theme.colorScheme.primary),
            ),
            AppStyle.hGap12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  AppStyle.vGap4,
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (action != null) ...[AppStyle.vGap4, action!],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.site,
    required this.item,
    required this.anchors,
    required this.compact,
    this.onTap,
    super.key,
  });

  final Site site;
  final AggregateSearchResult item;
  final bool anchors;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final hasTitle = item.title?.isNotEmpty == true;
    final title = anchors || !hasTitle ? item.author : item.title!;
    final subtitle = hasTitle ? (anchors ? item.title! : item.author) : '';
    final status = switch (item.live) {
      true => '直播中',
      false => '未开播',
      null => '状态未知',
    };
    final height = compact ? 44.0 : 52.0;
    final width = anchors ? height : (compact ? 60.0 : 82.0);
    final radius = anchors ? 28.0 : 8.0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: colors.surfaceContainerLow,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: item.image != null
                        ? NetImage(
                            item.image!,
                            width: width,
                            height: height,
                            borderRadius: radius,
                          )
                        : Center(
                            child: Image.asset(
                              site.logo,
                              width: 24,
                              height: 24,
                            ),
                          ),
                  ),
                ),
              ),
              AppStyle.hGap12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isEmpty ? site.name : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: caption,
                      ),
                    AppStyle.vGap4,
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(site.name, style: caption),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: item.live == true
                                ? colors.primaryContainer
                                : colors.surfaceContainerHighest,
                            borderRadius: AppStyle.radius8,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              status,
                              style: caption?.copyWith(
                                color: item.live == true
                                    ? colors.onPrimaryContainer
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                        if (item.accountId?.isNotEmpty == true)
                          Text('抖音号 ${item.accountId}', style: caption),
                        if (item.source != null)
                          Text(item.source!, style: caption),
                        if (item.roomId.isEmpty && item.profile != null)
                          Text('打开抖音主页', style: caption),
                      ],
                    ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                AppStyle.hGap4,
                ExcludeSemantics(
                  child: Icon(
                    item.roomId.isEmpty
                        ? Icons.open_in_new
                        : Icons.chevron_right_rounded,
                    size: compact ? 16 : 20,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
