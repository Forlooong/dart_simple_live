import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/app_update.dart';
import 'package:test/test.dart';

Map<String, dynamic> package({
  String arch = 'arm64',
  int build = 13124,
  String certificate = 'ab',
  int sdk = 24,
}) => {
  'platform': 'android',
  'arch': arch,
  'build': build,
  'size': 4,
  'minSdk': sdk,
  'certificate': certificate,
  'packageId': 'com.xycz.simple_live',
  'url': '$updateReleasePage/download/test/test.apk',
  'sha256': sha256.convert([1, 2, 3, 4]).toString(),
};

void main() {
  test(
    'official API can supply the manifest when the public asset route fails',
    () async {
      final body = jsonEncode({
        'schemaVersion': 1,
        'repository': 'Forlooong/dart_simple_live',
        'main': {
          'version': '1.12.24',
          'notes': '',
          'packages': [package()],
        },
      });
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (request.uri.path.endsWith('/releases/latest')) {
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: jsonEncode({
                    'tag_name': 'test',
                    'body': '修复开播提醒',
                    'published_at': '2026-11-18T06:00:00Z',
                    'assets': [
                      {
                        'name': 'update.json',
                        'id': 123,
                        'digest': 'sha256:${sha256.convert(utf8.encode(body))}',
                      },
                    ],
                  }),
                ),
              );
            } else if (request.uri.path.endsWith('/releases/assets/123')) {
              expect(request.headers['Accept'], 'application/octet-stream');
              handler.resolve(
                Response(requestOptions: request, statusCode: 200, data: body),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionTimeout,
                ),
              );
            }
          },
        ),
      );
      final update = await AppUpdateClient(client: dio).check('main');
      expect(update?.version, '1.12.24');
      expect(update?.notes, contains('修复开播提醒'));
      expect(update?.publishedAt, DateTime.utc(2026, 11, 18, 6));
      expect(update?.releaseUri, Uri.parse('$updateReleasePage/tag/test'));
    },
  );

  test(
    'embedded manifest only uses the GitHub API and matches the asset digest',
    () async {
      final body = utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'repository': updateRepository,
          'main': {
            'version': '1.12.24',
            'notes': '修复更新',
            'packages': [package()],
          },
        }),
      );
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            expect(request.uri.path.endsWith('/releases/latest'), isTrue);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: jsonEncode({
                  'tag_name': 'test',
                  'body':
                      '说明\n<!-- simple-live-update-manifest:v1\n${base64Encode(body)}\n-->',
                  'assets': [
                    {
                      'name': 'update.json',
                      'id': 123,
                      'digest': 'sha256:${sha256.convert(body)}',
                    },
                    {'name': 'test.apk', 'id': 456},
                  ],
                }),
              ),
            );
          },
        ),
      );
      final update = await AppUpdateClient(client: dio).check('main');
      expect(update?.notes, '修复更新');
      expect(update?.packages.single.assetId, 456);
    },
  );

  test('API rate limiting falls back to the public release manifest', () async {
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (request.uri.host == 'api.github.com') {
            handler.reject(
              DioException.badResponse(
                statusCode: 429,
                requestOptions: request,
                response: Response(requestOptions: request, statusCode: 429),
              ),
            );
            return;
          }
          expect(request.uri, Uri.parse(updateManifestUrl));
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: jsonEncode({
                'schemaVersion': 1,
                'repository': updateRepository,
                'tv': {
                  'version': '1.7.15',
                  'notes': '',
                  'packages': [package()],
                },
              }),
            ),
          );
        },
      ),
    );
    expect((await AppUpdateClient(client: dio).check('tv'))?.version, '1.7.15');
  });

  test(
    'Apple dotted bundle builds and Android split codes retain their meaning',
    () {
      expect(installedUpdateBuild('1.12.24.11125', platform: 'ios'), 11125);
      expect(installedUpdateBuild('13125', platform: 'android'), 13125);
      expect(installedUpdateBuild('1.12.24', platform: 'ios'), isNull);
    },
  );

  test(
    'selection preserves installed ABI, signature, SDK and increasing code',
    () {
      final update = AppUpdate({
        'version': '1.12.23',
        'notes': '',
        'packages': [package(), package(arch: 'arm32', build: 12124)],
      });
      UpdatePackage? select({
        String arch = 'arm64',
        String certificate = 'ab',
        int sdk = 24,
        int build = 13123,
      }) => update.select(
        platform: 'android',
        arch: arch,
        installedBuild: build,
        packageId: 'com.xycz.simple_live',
        certificate: certificate,
        sdk: sdk,
      );
      expect(select()?.build, 13124);
      expect(select(build: 13124), isNull);
      expect(select(certificate: 'other'), isNull);
      expect(select(sdk: 23), isNull);
      expect(select(arch: 'arm32'), isNull);
    },
  );
  test('duplicate packages and untrusted URLs are rejected', () {
    final update = AppUpdate({
      'version': '1.12.23',
      'notes': '',
      'packages': [package(), package()],
    });
    expect(
      () => update.select(
        platform: 'android',
        arch: 'arm64',
        installedBuild: 13123,
        packageId: 'com.xycz.simple_live',
        certificate: 'ab',
        sdk: 24,
      ),
      throwsFormatException,
    );
    expect(
      () =>
          UpdatePackage({...package(), 'url': 'https://example.com/test.apk'}),
      throwsFormatException,
    );
  });
  test(
    'download checks size and digest and removes incomplete files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'app-update-test-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var bytes = [1, 2, 3, 4];
      server.listen((request) {
        request.response.add(bytes);
        request.response.close();
      });
      final client = Dio();
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.baseUrl = '';
            options.path = 'http://127.0.0.1:${server.port}/test.apk';
            handler.next(options);
          },
        ),
      );
      try {
        final updater = AppUpdateClient(client: client);
        final good = UpdatePackage(package());
        final file = await updater.download(
          good,
          directory,
          cancel: CancelToken(),
          progress: (_, __) {},
        );
        expect(await file.readAsBytes(), [1, 2, 3, 4]);
        final bad = UpdatePackage({...package(), 'sha256': '00' * 32});
        await expectLater(
          updater.download(
            bad,
            directory,
            cancel: CancelToken(),
            progress: (_, __) {},
          ),
          throwsFormatException,
        );
        bytes = [1, 2, 3, 4, 5];
        final cached = await updater.download(
          good,
          directory,
          cancel: CancelToken(),
          progress: (_, __) {},
        );
        expect(await cached.readAsBytes(), [1, 2, 3, 4]);
        await cached.delete();
        await expectLater(
          updater.download(
            good,
            directory,
            cancel: CancelToken(),
            progress: (_, __) {},
          ),
          throwsFormatException,
        );
        expect(
          directory.listSync().where((f) => f.path.endsWith('.part')),
          isEmpty,
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
