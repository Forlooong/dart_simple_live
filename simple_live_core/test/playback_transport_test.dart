import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/playback_response.dart';
import 'package:simple_live_core/src/model/tars/get_cdn_token_ex_req.dart';
import 'package:simple_live_core/src/model/tars/get_cdn_token_ex_resp.dart';
import 'package:tars_dart/tars/net/base_tars_http.dart';
import 'package:test/test.dart';

class _Adapter implements HttpClientAdapter {
  Future<ResponseBody> Function(RequestOptions) respond;
  _Adapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

class _Bilibili extends BiliBiliSite {
  @override
  Future<Map<String, String>> getHeader() async => {};
}

LiveRoomDetail room([dynamic data]) => LiveRoomDetail(
  roomId: '1',
  title: '',
  cover: '',
  userName: '',
  userAvatar: '',
  online: 0,
  status: true,
  url: '',
  data: data,
);

ResponseBody response(dynamic data, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

Matcher failure(CoreErrorKind kind) =>
    isA<CoreError>().having((error) => error.kind, 'kind', kind);

void main() {
  late Dio original;
  late HttpClient client;
  late dynamic body;
  late int status;
  setUp(() {
    original = HttpClient.instance.dio;
    client = HttpClient();
    status = 200;
    body = {};
    client.dio.httpClientAdapter = _Adapter(
      (_) async => response(body, status),
    );
    HttpClient.instance.dio = client.dio;
    CoreLog.enableLog = false;
  });
  tearDown(() {
    HttpClient.instance.dio = original;
    client.dio.close(force: true);
    CoreLog.enableLog = true;
    CoreLog.onPrintLog = null;
    CoreLog.requestLogType = RequestLogType.short;
  });

  test(
    'HTTP failures retain safe timeout, cancellation, auth and rate types',
    () async {
      for (final entry in {
        401: CoreErrorKind.authRequired,
        403: CoreErrorKind.authRequired,
        429: CoreErrorKind.rateLimited,
        500: CoreErrorKind.transport,
      }.entries) {
        status = entry.key;
        await expectLater(
          client.getJson('https://example.test'),
          throwsA(failure(entry.value)),
        );
      }
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.cancel,
        DioExceptionType.connectionError,
      ]) {
        client.dio.httpClientAdapter = _Adapter(
          (options) async => throw DioException(
            requestOptions: options,
            type: type,
            message: 'PRIVATE_CANARY',
          ),
        );
        await expectLater(
          client.getJson('https://example.test'),
          throwsA(
            isA<CoreError>()
                .having(
                  (error) => error.kind,
                  'kind',
                  type == DioExceptionType.cancel
                      ? CoreErrorKind.cancelled
                      : type == DioExceptionType.connectionError
                      ? CoreErrorKind.transport
                      : CoreErrorKind.timeout,
                )
                .having(
                  (error) => error.toString(),
                  'safe message',
                  isNot(contains('PRIVATE_CANARY')),
                ),
          ),
        );
      }
      client.dio.httpClientAdapter = _Adapter(
        (_) async => ResponseBody.fromString(
          '{bad',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await expectLater(
        client.getJson('https://example.test'),
        throwsA(failure(CoreErrorKind.schemaChanged)),
      );
    },
  );

  test(
    'all logging modes exclude credentials, raw errors and payloads',
    () async {
      final logs = <String>[];
      CoreLog.enableLog = true;
      CoreLog.onPrintLog = (_, value) => logs.add(value);
      for (final mode in RequestLogType.values) {
        CoreLog.requestLogType = mode;
        for (final code in [200, 403]) {
          status = code;
          body = {'cookie': 'PRIVATE_CANARY'};
          try {
            await client.postJson(
              'https://example.test/PRIVATE_CANARY?token=PRIVATE_CANARY',
              data: {'password': 'PRIVATE_CANARY'},
              header: {
                'Cookie': 'PRIVATE_CANARY',
                'Authorization': 'PRIVATE_CANARY',
              },
            );
          } on CoreError {
            /* Expected HTTP error. */
          }
        }
      }
      CoreLog.error(const FormatException('PRIVATE_CANARY'));
    expect(logs, isNotEmpty);
      expect(logs.join('\n'), isNot(contains('PRIVATE_CANARY')));
      final previous = logs.length;
      CoreLog.requestLogType = RequestLogType.none;
      await expectLater(
        client.getJson('https://example.test'),
        throwsA(isA<CoreError>()),
      );
      expect(logs.length, previous);
    },
  );

  test(
    'TARS timeout has explicit units and deadline cancels a stalled server',
    () async {
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      final received = Completer<void>();
      server.listen((request) async {
        await request.drain<void>();
        if (!received.isCompleted) received.complete();
        // Deliberately never return a TARS response.
      });
      final tars = BaseTarsHttp('http://127.0.0.1:${server.port}', 'liveui');
      expect(tars.dio.options.connectTimeout, const Duration(seconds: 20));
      expect(tars.dio.options.sendTimeout, const Duration(seconds: 20));
      expect(tars.dio.options.receiveTimeout, const Duration(seconds: 20));
      final context = RequestContext(
        timeout: const Duration(milliseconds: 150),
      );
      try {
        final request = context.run(
          () => tars.tupRequest(
            'getCdnTokenInfoEx',
            GetCdnTokenExReq(),
            GetCdnTokenExResp(),
            cancelToken: context.cancelToken,
          ),
        );
        await expectLater(request, throwsA(failure(CoreErrorKind.timeout)));
        expect(received.isCompleted, isTrue);
        expect(context.cancelToken.isCancelled, isTrue);
      } finally {
        tars.dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'explicit cancellation reaches HTTP and excludes late success',
    () async {
      final entered = Completer<void>();
      final release = Completer<ResponseBody>();
      client.dio.httpClientAdapter = _Adapter((_) {
        entered.complete();
        return release.future;
      });
      final context = RequestContext();
      final pending = context.run(() => client.getJson('https://example.test'));
      final assertion = expectLater(
        pending,
        throwsA(failure(CoreErrorKind.cancelled)),
      );
      await entered.future;
      context.cancel();
      release.complete(response({'ok': true}));
      await assertion;
      expect(context.isCancelled, isTrue);
    },
  );

  test(
    'CDN collection isolates failure, bounds concurrency, preserves order and deduplicates',
    () async {
      var active = 0;
      var peak = 0;
      final urls = await collectPlaybackUrls<int>([0, 1, 2, 3], (index) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(Duration(milliseconds: index == 0 ? 15 : 1));
        active--;
        if (index == 1) {
          throw CoreError('failed', kind: CoreErrorKind.transport);
        }
        return 'https://cdn.test/${index == 3 ? 2 : index}';
      }, 'fixture');
      expect(peak, 2);
      expect(urls, ['https://cdn.test/0', 'https://cdn.test/2']);
      await expectLater(
        collectPlaybackUrls(
          [1, 2],
          (_) async => throw CoreError('failed', kind: CoreErrorKind.transport),
          'fixture',
        ),
        throwsA(failure(CoreErrorKind.noPlayableSource)),
      );
      expect(
        await collectPlaybackUrls([1, 2], (i) async {
          if (i == 1) throw CoreError('failed');
          return 'https://cdn.test/2';
        }, 'fixture'),
        ['https://cdn.test/2'],
      );
    },
  );

  test(
    'Bilibili playback validates shapes and stably partitions host CDN groups',
    () async {
      final site = _Bilibili();
      Map fixture(List<String> hosts) => {
        'code': 0,
        'data': {
          'live_status': 1,
          'playurl_info': {
            'playurl': {
              'g_qn_desc': [
                {'qn': 10000, 'desc': '原画'},
              ],
              'stream': [
                {
                  'format': [
                    {
                      'codec': [
                        {
                          'accept_qn': [10000],
                          'base_url': '/live',
                          'url_info': hosts
                              .map(
                                (host) => {
                                  'host': host,
                                  'extra': '?token=mcdn',
                                },
                              )
                              .toList(),
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          },
        },
      };
      for (final hosts in <List<String>>[
        ['https://a.test', 'https://b.test'],
        ['https://mcdn1.test', 'https://mcdn2.test'],
        [
          'https://mcdn1.test',
          'https://a.test',
          'https://mcdn2.test',
          'https://a.test',
        ],
      ]) {
        body = fixture(hosts);
        final expected = [
          ...hosts.where((h) => !Uri.parse(h).host.contains('mcdn')),
          ...hosts.where((h) => Uri.parse(h).host.contains('mcdn')),
        ];
        final quality = (await site.getPlayQualites(detail: room())).single;
      expect(quality.data, 10000);
      expect(quality.id, '10000');
        expect(
          (await site.getPlayUrls(
            detail: room(),
            quality: LivePlayQuality(quality: '', data: 10000),
          )).urls,
          expected.map((host) => '$host/live?token=mcdn').toList(),
        );
      }
      for (final entry in <(dynamic, CoreErrorKind)>[
        ({'code': -101}, CoreErrorKind.authRequired),
        ({'code': -412}, CoreErrorKind.rateLimited),
        (
          {
            'code': 0,
            'data': {'live_status': 0},
          },
          CoreErrorKind.offline,
        ),
        (
          {
            'code': 0,
            'data': {'playurl_info': null},
          },
          CoreErrorKind.noPlayableSource,
        ),
        (
          {
            'code': 0,
            'data': {
              'playurl_info': {
                'playurl': {'stream': [], 'g_qn_desc': []},
              },
            },
          },
          CoreErrorKind.noPlayableSource,
        ),
        (
          {
            'code': 0,
            'data': {
              'playurl_info': {
                'playurl': {'stream': null, 'g_qn_desc': []},
              },
            },
          },
          CoreErrorKind.schemaChanged,
        ),
      ]) {
        body = entry.$1;
        await expectLater(
          site.getPlayQualites(detail: room()),
          throwsA(failure(entry.$2)),
        );
      }
    },
  );

  test(
    'Douyu rejects business errors and invalid URL fields before composition',
    () async {
      final site = DouyuSite();
      body = {
        'error': 0,
        'data': {
          'rtmp_url': 'https://cdn.test',
          'rtmp_live': 'live?x=1&amp;y=2',
        },
      };
      expect(
        await site.getPlayUrl('1', '', 0, 'cdn'),
        'https://cdn.test/live?x=1&y=2',
      );
      for (final entry in <(dynamic, CoreErrorKind)>[
        ({'error': 403}, CoreErrorKind.authRequired),
        (
          {
            'error': 0,
            'data': {'rtmp_url': null},
          },
          CoreErrorKind.schemaChanged,
        ),
        (
          {
            'error': 0,
            'data': {'rtmp_url': 'file:///tmp', 'rtmp_live': 'live'},
          },
          CoreErrorKind.schemaChanged,
        ),
      ]) {
        body = entry.$1;
        await expectLater(
          site.getPlayUrl('1', '', 0, 'cdn'),
          throwsA(failure(entry.$2)),
        );
      }
    },
  );

  test(
    'Douyin headers are independent snapshots and prefer user credentials',
    () async {
      final site = DouyinSite()..cookie = 'first';
      final first = await site.getRequestHeaders();
      site.cookie = 'second';
      final second = await site.getRequestHeaders();
      expect(first['cookie'], 'first');
      expect(second['cookie'], 'second');
      first['cookie'] = 'mutated';
      expect((await site.getRequestHeaders())['cookie'], 'second');
    },
  );
}
