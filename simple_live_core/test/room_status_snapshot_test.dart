import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

class _Bilibili extends BiliBiliSite {
  @override
  Future<Map<String, String>> getHeader() async => {};

  @override
  Future<Map<String, String>> getWbiSign(String url) async => {
    'room_id': '123',
  };
}

void main() {
  late Dio original;
  late Dio intercepted;
  late List<String> requests;
  late Object Function(RequestOptions) respond;
  late Headers responseHeaders;

  setUp(() {
    original = HttpClient.instance.dio;
    requests = [];
    responseHeaders = Headers();
    intercepted = Dio();
    intercepted.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request.uri.path);
          try {
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: respond(request),
                headers: responseHeaders,
              ),
            );
          } catch (error) {
            handler.reject(DioException(requestOptions: request, error: error));
          }
        },
      ),
    );
    HttpClient.instance.dio = intercepted;
  });

  tearDown(() {
    HttpClient.instance.dio = original;
    intercepted.close();
  });

  test(
    'Bilibili status and start time use one room-info request, no danmaku token',
    () async {
      respond = (request) {
        expect(request.uri.path, '/xlive/web-room/v1/index/getInfoByRoom');
        return {
          'data': {
            'room_info': {'live_status': 1, 'live_start_time': 100},
          },
        };
      };
      final site = _Bilibili();
      final result = await site.getRoomStatusCached(
        roomId: '123',
        automatic: true,
      );
      expect(result.live, isTrue);
      expect(result.showTime, '100');
      await site.getRoomStatusCached(roomId: '123', automatic: true);
      expect(requests, hasLength(1));
      site.cookie = 'new-account';
      await site.getRoomStatusCached(roomId: '123', automatic: true);
      expect(requests, hasLength(2));
    },
  );

  for (final live in [false, true]) {
    test(
      'Douyu only fetches start time when live=$live, never signing JS',
      () async {
        respond = (request) => switch (request.uri.path) {
          '/betard/123' => {
            'room': {'show_status': live ? 1 : 2, 'videoLoop': 0},
          },
          '/swf_api/h5room/123' => {
            'data': {'show_time': 100},
          },
          _ => throw StateError('Unexpected request ${request.uri.path}'),
        };
        final status = await DouyuSite().getRoomStatusSnapshot(roomId: '123');
        expect(status.live, live);
        expect(status.showTime, live ? '100' : null);
        expect(requests, hasLength(live ? 2 : 1));
      },
    );
  }

  test(
    'Huya status needs one HTML request and no playback credentials',
    () async {
      respond = (request) {
        expect(request.uri.path, '/123');
        return '<script>window.HNF_GLOBAL_INIT = {"roomInfo":{"eLiveStatus":2}}</script>';
      };
      final status = await HuyaSite().getRoomStatusSnapshot(roomId: '123');
      expect(status.live, isTrue);
      expect(status.showTime, isNull);
      expect(requests, hasLength(1));
    },
  );

  test(
    'Douyin session-room status extracts data without preparing playback',
    () async {
      respond = (request) {
        expect(request.uri.path, '/webcast/room/reflow/info/');
        // Deliberately omit owner/cover/stream metadata required by getRoomDetail.
        return {
          'data': {
            'room': {'status': 2},
          },
        };
      };
      final site = DouyinSite();
      final status = await site.getRoomStatusSnapshot(
        roomId: '1234567890123456789',
      );
      expect(status.live, isTrue);
      expect(requests, hasLength(1));
      final version = site.statusConfigurationVersion;
      site.cookie = 'changed';
      expect(site.statusConfigurationVersion, version + 1);
    },
  );

  test(
    'Douyin live detail uses reflow start time and the page chat session',
    () async {
      const sessionId = '7711164227318254351';
      final webRoom = {
        'id_str': sessionId,
        'status': 2,
        'title': '直播间「测试」',
        'cover': {
          'url_list': ['cover'],
        },
        'owner': {
          'web_rid': '123',
          'nickname': '主播',
          'avatar_thumb': {
            'url_list': ['avatar'],
          },
        },
        'room_view_stats': {'display_value': 0},
      };
      respond = (request) {
        switch (request.uri.path) {
          case '/webcast/room/web/enter/':
            return {
              'data': {
                'data': [webRoom],
                'user': {},
              },
            };
          case '/webcast/room/reflow/info/':
            expect(request.uri.queryParameters['room_id'], sessionId);
            return {
              'data': {
                'room': {
                  ...webRoom,
                  'start_time': '1700000000000',
                },
              },
            };
          case '/123':
            expect(request.method, 'GET');
            responseHeaders.set('set-cookie', [
              'ttwid=fixture; Path=/; HttpOnly',
              'sessionid=ignored; Path=/; HttpOnly',
            ]);
            final state = jsonEncode({
              'state': {
                'appStore': {},
                'roomStore': {
                  'roomInfo': {'room': webRoom},
                },
                'userStore': {
                  'odin': {'user_unique_id': '7100000000000000222'},
                },
              },
            });
            return '<script>self.__pace_f.push([1,${jsonEncode('1:$state]\n')}])</script>';
          default:
            throw StateError('Unexpected request ${request.uri.path}');
        }
      };

      final site = DouyinSite();
      final detail = await site.getRoomDetail(roomId: '123');
      expect(detail.title, '直播间「测试」');
      expect(detail.showTime, '1700000000');
      final chat = detail.danmakuData as DouyinDanmakuArgs;
      expect(chat.roomId, sessionId);
      expect(chat.userId, '7100000000000000222');
      expect(chat.cookie, 'ttwid=fixture');

      site.cookie = 'ttwid=outdated; sessionid=signed-in';
      final reflow = await site.getRoomDetail(roomId: sessionId);
      expect(reflow.showTime, detail.showTime);
      final reflowChat = reflow.danmakuData as DouyinDanmakuArgs;
      expect(reflowChat.userId, chat.userId);
      expect(reflowChat.cookie, 'ttwid=fixture; sessionid=signed-in');
    },
  );

  test('malformed status remains an error, not an offline result', () async {
    respond = (_) => {
      'room': {'show_status': 'bad'},
    };
    await expectLater(
      DouyuSite().getRoomStatusSnapshot(roomId: '123'),
      throwsFormatException,
    );
  });
}
