import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/app_update.dart';
import 'package:test/test.dart';

Map<String, dynamic> package({String arch = 'arm64', int build = 13124,
    String certificate = 'ab', int sdk = 24}) => {
  'platform': 'android', 'arch': arch, 'build': build, 'size': 4,
  'minSdk': sdk, 'certificate': certificate,
  'packageId': 'com.xycz.simple_live',
  'url': '$updateReleasePage/download/test/test.apk',
  'sha256': sha256.convert([1, 2, 3, 4]).toString(),
};

void main() {
  test('selection preserves installed ABI, signature, SDK and increasing code', () {
    final update = AppUpdate({'version': '1.12.23', 'notes': '', 'packages': [
      package(), package(arch: 'arm32', build: 12124),
    ]});
    UpdatePackage? select({String arch = 'arm64', String certificate = 'ab',
        int sdk = 24, int build = 13123}) => update.select(platform: 'android',
      arch: arch, installedBuild: build, packageId: 'com.xycz.simple_live',
      certificate: certificate, sdk: sdk);
    expect(select()?.build, 13124);
    expect(select(build: 13124), isNull);
    expect(select(certificate: 'other'), isNull);
    expect(select(sdk: 23), isNull);
    expect(select(arch: 'arm32'), isNull);
  });
  test('duplicate packages and untrusted URLs are rejected', () {
    final update = AppUpdate({'version': '1.12.23', 'notes': '',
      'packages': [package(), package()]});
    expect(() => update.select(platform: 'android', arch: 'arm64',
      installedBuild: 13123, packageId: 'com.xycz.simple_live',
      certificate: 'ab', sdk: 24), throwsFormatException);
    expect(() => UpdatePackage({...package(), 'url': 'https://example.com/test.apk'}),
      throwsFormatException);
  });
  test('download checks size and digest and removes incomplete files', () async {
    final directory = await Directory.systemTemp.createTemp('app-update-test-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.add([1, 2, 3, 4]);
      request.response.close();
    });
    final client = Dio();
    client.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.baseUrl = '';
      options.path = 'http://127.0.0.1:' + server.port.toString() + '/test.apk';
      handler.next(options);
    }));
    try {
      final updater = AppUpdateClient(client: client);
      final good = UpdatePackage(package());
      final file = await updater.download(good, directory,
        cancel: CancelToken(), progress: (_, __) {});
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      final bad = UpdatePackage({...package(), 'sha256': '00' * 32});
      await expectLater(updater.download(bad, directory,
        cancel: CancelToken(), progress: (_, __) {}), throwsFormatException);
      expect(directory.listSync().where((f) => f.path.endsWith('.part')), isEmpty);
    } finally {
      client.close(force: true);
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
}
