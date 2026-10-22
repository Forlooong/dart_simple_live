import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Storage extends LocalStorageService {
  String saved = '';
  Completer<void>? hold;
  bool fail = false;
  @override
  Future<void> setValue<T>(dynamic key, T value) async {
    await hold?.future;
    if (fail) throw StateError('vault unavailable');
    saved = value as String;
  }
}

class _Adapter implements HttpClientAdapter {
  final responses = <Completer<ResponseBody>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final response = Completer<ResponseBody>();
    responses.add(response);
    return response.future;
  }

  @override
  void close({bool force = false}) {}
  void complete(int index, {bool valid = true}) {
    responses[index].complete(
      ResponseBody.fromString(
        jsonEncode({
          'code': valid ? 0 : -101,
          'data': {'mid': 101, 'uname': 'old account'},
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  late _Adapter adapter;
  late BiliBiliAccountService account;
  late BiliBiliSite site;
  late Dio originalDio;
  setUp(() {
    storage = _Storage();
    Get.put<LocalStorageService>(storage);
    adapter = _Adapter();
    originalDio = HttpClient.instance.dio;
    HttpClient.instance.dio = Dio()..httpClientAdapter = adapter;
    account = BiliBiliAccountService();
    site = Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite;
    site.cookie = '';
    site.userId = 0;
  });
  tearDown(() async {
    HttpClient.instance.dio.close(force: true);
    HttpClient.instance.dio = originalDio;
    site.cookie = '';
    site.userId = 0;
    await storage.credentialChanges.close();
    Get.reset();
  });
  Future<void> requested() async {
    for (var i = 0; i < 30 && adapter.responses.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(adapter.responses, hasLength(1));
  }

  test(
    'late account A success cannot attach its user ID to cookie B',
    () async {
      await account.setCookie('A');
      final old = account.loadUserInfo();
      await requested();
      await account.setCookie('B');
      adapter.complete(0);
      await old;
      expect(account.cookie, 'B');
      expect(account.uid, 0);
      expect(site.cookie, 'B');
      expect(site.userId, 0);
      expect(storage.saved, 'B');
    },
  );

  test('late account A failure cannot log out cookie B', () async {
    await account.setCookie('A');
    final old = account.loadUserInfo();
    await requested();
    await account.setCookie('B');
    adapter.complete(0, valid: false);
    await old;
    expect(account.cookie, 'B');
    expect(account.logined.value, isTrue);
    expect(storage.saved, 'B');
  });

  test(
    'pending vault write invalidates old user info before it completes',
    () async {
      await account.setCookie('A');
      final old = account.loadUserInfo();
      await requested();
      final gate = storage.hold = Completer<void>();
      final replacement = account.setCookie('B');
      adapter.complete(0, valid: false);
      await old;
      expect(account.cookie, 'A');
      gate.complete();
      storage.hold = null;
      await replacement;
      expect(account.cookie, 'B');
      expect(storage.saved, 'B');
    },
  );

  test(
    'failed vault write preserves the current account and provider',
    () async {
      await account.setCookie('A');
      storage.fail = true;
      await expectLater(account.setCookie('B'), throwsStateError);
      expect(account.cookie, 'A');
      expect(site.cookie, 'A');
      expect(storage.saved, 'A');
    },
  );
}
