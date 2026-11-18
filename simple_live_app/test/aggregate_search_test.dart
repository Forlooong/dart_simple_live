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
    },
  );
}
