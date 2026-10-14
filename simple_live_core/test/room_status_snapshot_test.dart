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

  setUp(() {
    original = HttpClient.instance.dio;
    requests = [];
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
