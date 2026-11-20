import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/search/aggregate_search.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Site extends LiveSite {
  final pending = <(String, int), Completer<LiveSearchRoomResult>>{};
  final contexts = <(String, int), RequestContext>{};

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    contexts[(keyword, page)] = RequestContext.current!;
    return (pending[(keyword, page)] = Completer()).future;
  }
}

LiveSearchRoomResult _result(String name, {bool more = false}) =>
    LiveSearchRoomResult(
      hasMore: more,
      items: [
        LiveRoomItem(roomId: '1', title: '直播间', cover: '', userName: name),
      ],
    );

void main() {
  test(
    'aggregates only when selected and guards old requests and paging',
    () async {
      final first = _Site();
      final second = _Site();
      final search = AggregateSearch({'bilibili': first, 'huya': second});
      addTearDown(search.dispose);
      search.reset('older', searchAnchors: false);
      expect(first.pending, isEmpty);
      search.setActive(true);
      expect(first.pending, hasLength(1));
      expect(second.pending, hasLength(1));
      search.reset('newer', searchAnchors: false);
      expect(first.contexts[('older', 1)]!.isCancelled, isTrue);
      first.pending[('older', 1)]!.complete(_result('old'));
      second.pending[('older', 1)]!.complete(_result('old'));
      first.pending[('newer', 1)]!.complete(_result('new', more: true));
      await Future<void>.delayed(Duration.zero);
      final platform = search.platforms['bilibili']!;
      expect(platform.results['1']!.author, 'new');
      expect(platform.results['1']!.live, isNull);
      expect(search.platforms['huya']!.loading, isTrue);
      final paging = search.load('bilibili');
      first.pending[('newer', 2)]!.complete(_result('new'));
      await paging;
      expect(platform.results, hasLength(1));
      expect(platform.hasMore, isFalse);
      second.pending[('newer', 1)]!.complete(_result('new'));
      await Future<void>.delayed(Duration.zero);
      expect(search.platforms['huya']!.results['1']!.author, 'new');
      expect(search.ordered, [('bilibili', '1'), ('huya', '1')]);
    },
  );
  test('platform tabs request only the selected platform', () {
    final first = _Site();
    final second = _Site();
    final search = AggregateSearch({'bilibili': first, 'huya': second});
    addTearDown(search.dispose);
    search.setActive(true);
    search.selectPlatform('huya');
    search.reset('test', searchAnchors: false);
    expect(first.pending, isEmpty);
    expect(second.pending, hasLength(1));
    search.selectPlatform('bilibili');
    expect(second.contexts[('test', 1)]!.isCancelled, isTrue);
    expect(first.pending, hasLength(1));
  });

  test(
    'keeps local Douyin results when upstream search requires login',
    () async {
      final site = _Site();
      final search = AggregateSearch(
        {'douyin': site},
        localDouyinResults: (_) => [
          (
            roomId: '1243',
            author: '离线主播',
            title: null,
            live: false,
            profile: null,
            source: '本机关注',
            accountId: null,
          ),
        ],
      );
      addTearDown(search.dispose);
      search.setActive(true);
      search.reset('offline_id', searchAnchors: false);
      expect(search.platforms['douyin']!.results['1243']!.source, '本机关注');
      site.pending[('offline_id', 1)]!.completeError(
        CoreError('抖音搜索需要登录', kind: CoreErrorKind.authRequired),
      );
      await Future<void>.delayed(Duration.zero);
      expect(search.platforms['douyin']!.results['1243']!.author, '离线主播');
      expect(search.platforms['douyin']!.failure, CoreErrorKind.authRequired);
      expect(search.ordered, [('douyin', '1243')]);
    },
  );

  test('web fallback keeps the live or user search mode', () {
    final live = douyinWebSearchUri('王者荣耀', anchors: false);
    expect(live.host, 'www.douyin.com');
    expect(Uri.decodeComponent(live.path), '/search/王者荣耀');
    expect(live.queryParameters['type'], 'live');
    final user = douyinWebSearchUri('王者荣耀', anchors: true);
    expect(user.queryParameters['type'], 'user');
  });

  test('Douyin keyword login failure leaves room links searchable', () async {
    final site = _Site();
    final search = AggregateSearch({'douyin': site})..setActive(true);
    addTearDown(search.dispose);
    search.reset('主播', searchAnchors: false);
    site.pending[('主播', 1)]!.completeError(
      CoreError('需要登录', kind: CoreErrorKind.authRequired),
    );
    await Future<void>.delayed(Duration.zero);
    expect(search.platforms['douyin']!.failure, CoreErrorKind.authRequired);

    const link = 'https://live.douyin.com/1234';
    search.reset(link, searchAnchors: false);
    site.pending[(link, 1)]!.complete(_result('房间直链'));
    await Future<void>.delayed(Duration.zero);
    expect(search.platforms['douyin']!.results['1']!.author, '房间直链');
  });

  test(
    'Douyin partial failure leaves successful pagination available',
    () async {
      final site = _Site();
      final search = AggregateSearch({'douyin': site})..setActive(true);
      addTearDown(search.dispose);
      search.reset('主播', searchAnchors: false);
      final first = _result('第一页', more: true);
      site.pending[('主播', 1)]!.complete(
        LiveSearchRoomResult(
          items: first.items,
          hasMore: first.hasMore,
          partialFailure: CoreError('需要登录', kind: CoreErrorKind.authRequired),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final paging = search.load('douyin');
      site.pending[('主播', 2)]!.complete(_result('第二页'));
      await paging;
      expect(search.platforms['douyin']!.results['1']!.author, '第二页');
    },
  );

  test('anchor mode keeps profile-only rows for browser opening', () async {
    final site = _AnchorSite();
    final search = AggregateSearch({'douyin': site});
    addTearDown(search.dispose);
    search.setActive(true);
    search.reset('主播', searchAnchors: true);
    await Future<void>.delayed(Duration.zero);

    expect(site.keyword, '主播');
    final result = search.platforms['douyin']!.results.values.single;
    expect(result.roomId, isEmpty);
    expect(result.profile.toString(), 'https://www.douyin.com/user/test');
    expect(result.author, '仅有主页的主播');
    expect(result.live, isFalse);
    expect(result.title, isNull);
  });
}

class _AnchorSite extends LiveSite {
  String? keyword;
  int? page;

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    this.keyword = keyword;
    this.page = page;
    return LiveSearchAnchorResult(
      hasMore: false,
      items: [
        LiveAnchorItem(
          roomId: '',
          profile: Uri.parse('https://www.douyin.com/user/test'),
          avatar: '',
          userName: '仅有主页的主播',
          liveStatus: false,
          statusKnown: true,
        ),
      ],
    );
  }
}
