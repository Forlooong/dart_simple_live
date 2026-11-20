import 'dart:async';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

LiveCategory _category(int id) =>
    LiveCategory(id: '$id,1', name: '分区$id', children: <LiveSubCategory>[]);

LiveRoomItem _room(String id, {int? online, String name = '房间'}) =>
    LiveRoomItem(
      roomId: id,
      title: name,
      cover: '',
      userName: name,
      online: online ?? 0,
      onlineKnown: online != null,
    );

LiveCategoryResult _result(List<LiveRoomItem> items) =>
    LiveCategoryResult(hasMore: false, items: items);

void main() {
  test(
    'merges partitions, deduplicates and sorts by current viewers',
    () async {
      final requested = <String>[];
      final site = DouyinSite(
        categoryLoader: () async => [
          for (var id = 1; id <= 10; id++) _category(id),
        ],
        partitionLoader:
            (
              partitionId,
              partitionType, {
              required count,
              int offset = 0,
            }) async {
              requested.add(partitionId);
              if (partitionId == '720') {
                return _result([
                  _room('100', online: 85),
                  _room('200', online: 3000),
                  _room('300', online: 500),
                ]);
              }
              final base = int.parse(partitionId) * 100;
              return _result([
                for (var index = 0; index < 5; index++)
                  _room('${base + index}', online: base - index * 10),
              ]);
            },
      );

      final first = await site.getRecommendRooms();
      expect(first.items, hasLength(15));
      expect(first.items.first.roomId, '200');
      expect(first.items.first.online, 3000);
      expect(
        first.items.map((item) => item.online).toList(),
        orderedEquals(
          [...first.items.map((item) => item.online)]..sort((a, b) => b - a),
        ),
      );
      expect(requested.where((id) => id == '720'), hasLength(1));
      expect(requested, containsAll(['1', '2', '3', '4', '5', '6', '7', '8']));
      expect(requested, isNot(contains('9')));
      expect(requested, isNot(contains('10')));
      expect(requested, hasLength(9));

      final second = await site.getRecommendRooms(page: 2);
      expect(second.items, hasLength(15));
      expect(second.hasMore, isTrue);
      final third = await site.getRecommendRooms(page: 3);
      expect(third.items, hasLength(10));
      expect(third.hasMore, isFalse);
      final fourth = await site.getRecommendRooms(page: 4);
      expect(fourth.items, isEmpty);
      expect(fourth.hasMore, isFalse);
      // Paging reuses the refresh snapshot instead of re-querying partitions.
      expect(requested, hasLength(9));
    },
  );

  test(
    'keeps collection order for equal viewers and puts unknown last',
    () async {
      final site = DouyinSite(
        categoryLoader: () async => [_category(1), _category(2)],
        partitionLoader:
            (
              partitionId,
              partitionType, {
              required count,
              int offset = 0,
            }) async {
              return switch (partitionId) {
                '720' => _result([
                  _room('a', online: 100),
                  _room('b', online: 100),
                ]),
                '1' => _result([
                  _room('c', online: 100),
                  _room('d', online: 100),
                ]),
                _ => _result([_room('e'), _room('f')]),
              };
            },
      );

      final result = await site.getRecommendRooms();
      expect(
        result.items.map((item) => item.roomId).toList(),
        orderedEquals(['a', 'b', 'c', 'd', 'e', 'f']),
      );
      expect(result.items.take(4).every((item) => item.onlineKnown), isTrue);
      expect(result.items.skip(4).every((item) => !item.onlineKnown), isTrue);
    },
  );

  test('deduplicates by stable room id across partitions', () async {
    final site = DouyinSite(
      categoryLoader: () async => [_category(1)],
      partitionLoader:
          (partitionId, partitionType, {required count, int offset = 0}) async {
            return switch (partitionId) {
              '720' => _result([
                _room('same', online: 10, name: '推荐'),
                _room('other', online: 20),
              ]),
              _ => _result([
                _room('same', online: 1000, name: '分区'),
                _room('tail', online: 5),
              ]),
            };
          },
    );

    final result = await site.getRecommendRooms();
    expect(result.items.map((item) => item.roomId).toList(), [
      'other',
      'same',
      'tail',
    ]);
    expect(result.items.firstWhere((item) => item.roomId == 'same').online, 10);
    expect(result.items.map((item) => item.roomId).toSet(), hasLength(3));
  });

  test('starts a new snapshot on every first page refresh', () async {
    var loads = 0;
    final site = DouyinSite(
      categoryLoader: () async => <LiveCategory>[],
      partitionLoader:
          (partitionId, partitionType, {required count, int offset = 0}) async {
            loads++;
            return _result([_room('room${loads.toString()}', online: 1)]);
          },
    );

    final first = await site.getRecommendRooms();
    expect(first.items.single.roomId, 'room1');
    final second = await site.getRecommendRooms();
    expect(second.items.single.roomId, 'room2');
    expect(loads, 2);
  });

  test('overlapping refreshes share a stable snapshot for paging', () async {
    final pending = Completer<LiveCategoryResult>();
    var loads = 0;
    final site = DouyinSite(
      categoryLoader: () async => [],
      partitionLoader: (_, _, {required count, int offset = 0}) {
        loads++;
        return pending.future;
      },
    );

    final first = site.getRecommendRooms();
    final second = site.getRecommendRooms();
    await Future<void>.delayed(Duration.zero);
    pending.complete(
      _result([for (var i = 1; i <= 16; i++) _room('$i', online: 17 - i)]),
    );

    expect((await first).items.first.roomId, '1');
    expect((await second).items.first.roomId, '1');
    expect((await site.getRecommendRooms(page: 2)).items.single.roomId, '16');
    expect(loads, 1);
  });

  test('uses successful partitions when another partition fails', () async {
    final site = DouyinSite(
      categoryLoader: () async => [_category(1), _category(2)],
      partitionLoader:
          (partitionId, partitionType, {required count, int offset = 0}) async {
            if (partitionId == '2') {
              throw CoreError('limited', kind: CoreErrorKind.rateLimited);
            }
            return _result([_room('room-$partitionId', online: 1)]);
          },
    );

    final result = await site.getRecommendRooms();
    expect(result.items.map((item) => item.roomId).toList(), [
      'room-720',
      'room-1',
    ]);
  });

  test('throws a retryable error when every partition fails', () async {
    final site = DouyinSite(
      categoryLoader: () async => [_category(1)],
      partitionLoader:
          (partitionId, partitionType, {required count, int offset = 0}) async {
            throw CoreError('offline', kind: CoreErrorKind.transport);
          },
    );

    await expectLater(
      site.getRecommendRooms(),
      throwsA(
        isA<CoreError>()
            .having((error) => error.kind, 'kind', CoreErrorKind.transport)
            .having((error) => error.retriable, 'retriable', isTrue)
            .having((error) => error.failures, 'failures', isNotEmpty),
      ),
    );
  });

  test('limits partition requests to four concurrent calls', () async {
    var active = 0;
    var maximum = 0;
    final site = DouyinSite(
      categoryLoader: () async => [
        for (var id = 1; id <= 8; id++) _category(id),
      ],
      partitionLoader:
          (partitionId, partitionType, {required count, int offset = 0}) async {
            active++;
            if (active > maximum) maximum = active;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            active--;
            return _result([_room('room-$partitionId', online: 1)]);
          },
    );

    final result = await site.getRecommendRooms();
    expect(result.items, hasLength(9));
    expect(maximum, 4);
  });

  test('keeps the recommendation when categories cannot be loaded', () async {
    final site = DouyinSite(
      categoryLoader: () async =>
          throw CoreError('schema', kind: CoreErrorKind.schemaChanged),
      partitionLoader:
          (partitionId, partitionType, {required count, int offset = 0}) async {
            return _result([_room('recommend', online: 12)]);
          },
    );

    final result = await site.getRecommendRooms();
    expect(result.items.single.roomId, 'recommend');
    expect(result.items.single.online, 12);
  });

  test('parses escaped category payloads from the live page', () {
    const category =
        '{"partition":{"id_str":"101","type":4,"title":"聊天"},'
        '"sub_partition":[{"partition":{"id_str":"1011","type":4,'
        '"title":"聊天室"}}]}';
    final html = '{"pathname":"/","categoryData":[$category]}';
    final slashQuote = String.fromCharCodes(const [92, 34]);
    final escapedHtml = html.replaceAll('"', slashQuote);

    for (final page in [escapedHtml, html]) {
      final categories = DouyinSite.parseCategories(page);
      expect(categories, hasLength(1));
      expect(categories.single.id, '101,4');
      expect(categories.single.name, '聊天');
      expect(categories.single.children.first.id, '101,4');
      expect(categories.single.children.last.id, '1011,4');
      expect(categories.single.children.last.name, '聊天室');
    }
  });

  test('parses partition rooms with current viewer counts', () {
    final result = DouyinSite.parsePartitionRooms({
      'data': {
        'data': [
          {
            'web_rid': '1',
            'room': {
              'title': 'A',
              'cover': {
                'url_list': ['c'],
              },
              'owner': {'nickname': 'u'},
              'user_count': 2808,
            },
          },
          {
            'web_rid': '2',
            'room': {
              'title': 'B',
              'cover': {
                'url_list': ['c'],
              },
              'owner': {'nickname': 'u'},
              'stats': {'total_user': 500000},
              'room_view_stats': {
                'display_value': 500000,
                'display_long': '50万累计观看',
              },
            },
          },
          {
            'web_rid': '3',
            'room': {
              'title': 'C',
              'cover': {
                'url_list': ['c'],
              },
              'owner': {'nickname': 'u'},
              'room_view_stats': {
                'display_value': '8.3万',
                'display_long': '8.3万在线观众',
              },
            },
          },
          {
            'web_rid': '4',
            'room': {
              'title': 'D',
              'cover': {
                'url_list': ['c'],
              },
              'owner': {'nickname': 'u'},
              'user_count': 0,
              'room_view_stats': {'display_value': 500},
            },
          },
        ],
      },
    }, count: 5);

    expect(result.hasMore, isFalse);
    expect(result.items.map((item) => item.roomId).toList(), [
      '1',
      '2',
      '3',
      '4',
    ]);
    expect(result.items.map((item) => item.online).toList(), [
      2808,
      0,
      83000,
      0,
    ]);
    expect(result.items.map((item) => item.onlineKnown).toList(), [
      true,
      false,
      true,
      true,
    ]);
  });
}
