import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  test('keeps offline users and separates profile and room identifiers', () {
    final result = DouyinSite.parseUserSearch({
      'has_more': 1,
      'user_list': [
        {
          'user_info': {
            'nickname': '同名主播',
            'unique_id': 'account_a',
            'sec_uid': 'user_A',
            'web_rid': '1234',
            'room_id': '1234567890123456789',
            'live_status': 4,
          },
        },
        {
          'user_info': {
            'nickname': '同名主播',
            'unique_id': 'account_b',
            'sec_uid': 'user_B',
            'room_id': '1234567890123456789',
          },
        },
        {
          'user_info': {
            'nickname': '直播主播',
            'sec_uid': 'user_C',
            'web_rid': '5678',
            'live_status': 2,
          },
        },
        {
          'user_info': {'nickname': '无有效入口', 'web_rid': '0'},
        },
      ],
    });
    expect(result.hasMore, isTrue);
    expect(result.items, hasLength(3));
    expect(result.items.first.roomId, '1234');
    expect(result.items.first.accountId, 'account_a');
    expect(result.items.first.liveStatus, isFalse);
    expect(result.items.first.statusKnown, isTrue);
    expect(result.items[1].roomId, isEmpty);
    expect(result.items[1].profile!.path, '/user/user_B');
    expect(result.items[1].statusKnown, isFalse);
    expect(result.items.last.liveStatus, isTrue);
  });

  test('unexpected response has a distinct schema error', () {
    expect(
      () => DouyinSite.parseUserSearch({}),
      throwsA(
        isA<CoreError>().having(
          (error) => error.kind,
          'kind',
          CoreErrorKind.schemaChanged,
        ),
      ),
    );
  });
  test(
    'room search retains an offline account when live search is limited',
    () async {
      final client = HttpClient.instance;
      final original = client.dio;
      final testDio = Dio();
      client.dio = testDio;
      addTearDown(() {
        client.dio = original;
        testDio.close();
      });
      testDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.uri.path.endsWith('/discover/search/')) {
              expect(options.uri.queryParameters['keyword'], 'offline_id');
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'status_code': 0,
                    'has_more': 0,
                    'user_list': [
                      {
                        'user_info': {
                          'nickname': '离线主播',
                          'web_rid': '1243',
                          'sec_uid': 'test_profile',
                          'live_status': 4,
                        },
                      },
                    ],
                  },
                ),
              );
              return;
            }
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: options, statusCode: 429),
              ),
            );
          },
        ),
      );
      final site = DouyinSite()..cookie = 'test_session=fixture';
      final result = await site.searchRooms('offline_id');
      expect(result.partialFailure?.kind, CoreErrorKind.rateLimited);
      expect(result.items.single.userName, '离线主播');
      expect(result.items.single.roomId, '1243');
      expect(result.items.single.liveStatus, false);
    },
  );

  test('business login code 2483 is reported as an auth requirement', () async {
    final client = HttpClient.instance;
    final original = client.dio;
    final testDio = Dio();
    client.dio = testDio;
    addTearDown(() {
      client.dio = original;
      testDio.close();
    });
    testDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'status_code': 2483, 'status_msg': '请先登录'},
            ),
          );
        },
      ),
    );
    final site = DouyinSite()..cookie = 'test_session=fixture';

    await expectLater(
      site.searchRooms('王者荣耀'),
      throwsA(
        isA<CoreError>()
            .having((error) => error.kind, 'kind', CoreErrorKind.authRequired)
            .having((error) => error.message, 'message', contains('登录')),
      ),
    );
  });

  test('business rate-limit message is reported as rate limited', () async {
    final client = HttpClient.instance;
    final original = client.dio;
    final testDio = Dio();
    client.dio = testDio;
    addTearDown(() {
      client.dio = original;
      testDio.close();
    });
    testDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'status_code': 8, 'status_msg': '请求过于频繁，请稍后再试'},
            ),
          );
        },
      ),
    );
    final site = DouyinSite()..cookie = 'test_session=fixture';

    await expectLater(
      site.searchRooms('王者荣耀'),
      throwsA(
        isA<CoreError>().having(
          (error) => error.kind,
          'kind',
          CoreErrorKind.rateLimited,
        ),
      ),
    );
  });

  test('empty business response stays a true empty result', () async {
    final client = HttpClient.instance;
    final original = client.dio;
    final testDio = Dio();
    client.dio = testDio;
    addTearDown(() {
      client.dio = original;
      testDio.close();
    });
    testDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final live = options.uri.path.endsWith('/live/search/');
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: live
                  ? {'status_code': 0, 'data': <Object>[], 'has_more': 0}
                  : {'status_code': 0, 'user_list': <Object>[], 'has_more': 0},
            ),
          );
        },
      ),
    );
    final site = DouyinSite()..cookie = 'test_session=fixture';

    final result = await site.searchRooms('没有这个主播');
    expect(result.items, isEmpty);
    expect(result.hasMore, isFalse);
    expect(result.partialFailure, isNull);
  });

  test('2483 keeps an offline account from the user search', () async {
    final client = HttpClient.instance;
    final original = client.dio;
    final testDio = Dio();
    client.dio = testDio;
    addTearDown(() {
      client.dio = original;
      testDio.close();
    });
    testDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.path.endsWith('/discover/search/')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'status_code': 0,
                  'has_more': 0,
                  'user_list': [
                    {
                      'user_info': {
                        'nickname': '离线主播',
                        'web_rid': '1243',
                        'sec_uid': 'test_profile',
                        'live_status': 4,
                      },
                    },
                  ],
                },
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'status_code': 2483, 'status_msg': '请先登录'},
            ),
          );
        },
      ),
    );
    final site = DouyinSite()..cookie = 'test_session=fixture';

    final result = await site.searchRooms('offline_id');
    expect(result.partialFailure?.kind, CoreErrorKind.authRequired);
    expect(result.items.single.userName, '离线主播');
    expect(result.items.single.roomId, '1243');
    expect(result.items.single.liveStatus, isFalse);
    expect(result.hasMore, isFalse);
  });

  test('direct live room link uses the independent room query', () async {
    final site = _DirectLinkSite();

    final result = await site.searchRooms('https://live.douyin.com/123456');
    expect(site.requested, ['123456']);
    expect(result.items.single.roomId, '123456');
    expect(result.items.single.title, '直链房间');
    expect(result.hasMore, isFalse);
  });
}

class _DirectLinkSite extends DouyinSite {
  final requested = <String>[];

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    requested.add(roomId);
    return LiveRoomDetail(
      roomId: roomId,
      title: '直链房间',
      cover: '',
      userName: '主播',
      userAvatar: '',
      online: 0,
      status: true,
      url: 'https://live.douyin.com/$roomId',
    );
  }
}
