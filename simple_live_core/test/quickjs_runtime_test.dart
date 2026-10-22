import 'dart:async';

import 'package:dart_quickjs/dart_quickjs.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/request_context.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';
import 'package:simple_live_core/src/scripts/douyu_sign.dart';
import 'package:test/test.dart';

void main() {
  test('UTF-8 eval, function and global strings preserve Unicode and NUL', () {
    final runtime = JsRuntime();
    try {
      expect(runtime.eval('"中文😀"'), '中文😀');
      expect(runtime.eval(r'"\u4e2d\u6587\ud83d\ude00"'), '中文😀');
      final function = runtime.evalFunction('(x) => x + "中文😀"');
      try {
        for (final value in ['', 'ASCII', '中文😀', 'a\u0000b']) {
          runtime.setGlobal('value', value);
          expect(runtime.getGlobal('value'), value);
          expect(function.call([value]), '$value中文😀');
        }
        for (final value in [null, true, false, 123, 1.5]) {
          runtime.setGlobal('value', value);
          expect(runtime.getGlobal('value'), value);
        }
      } finally {
        function.dispose();
      }
    } finally {
      runtime.dispose();
      runtime.dispose();
    }
  });

  test('native interrupt stops infinite execution and output is bounded', () {
    final runtime = JsRuntime(
      executionTimeout: const Duration(milliseconds: 50),
    );
    final clock = Stopwatch()..start();
    try {
      expect(() => runtime.eval('for (;;) {}'), throwsA(isA<JsException>()));
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    } finally {
      runtime.dispose();
    }
    final limited = JsRuntime(maxStringBytes: 4);
    try {
      expect(() => limited.eval('"中文"'), throwsA(isA<JsException>()));
      expect(limited.eval('"ok"'), 'ok');
    } finally {
      limited.dispose();
    }
  });

  test(
    'argument and JavaScript conversion failures leave a usable runtime',
    () {
      final runtime = JsRuntime();
      final function = runtime.evalFunction('(a, b) => a');
      try {
        expect(
          () => function.call(['allocated', Object()]),
          throwsA(isA<JsInvalidValueException>()),
        );
        expect(
          () => runtime.setGlobal('value', ['allocated', Object()]),
          throwsA(isA<JsInvalidValueException>()),
        );
        expect(
          () => runtime.setGlobal('value', {'allocated': Object()}),
          throwsA(isA<JsInvalidValueException>()),
        );
        expect(
          () => runtime.eval(
            'const circular = {}; circular.self = circular; circular',
          ),
          throwsA(isA<JsException>()),
        );
        expect(function.call(['中文']), '中文');
      } finally {
        function.dispose();
        runtime.dispose();
      }
    },
  );

  test('signing uses bounded worker and releases repeated failures', () async {
    expect(
      await DouyuSign.getSign(
        'function ub98484234(r) { return r + "中文😀"; }',
        '123',
      ),
      '123中文😀',
    );
    for (var index = 0; index < 10; index++) {
      await expectLater(
        DouyuSign.getSign('throw new Error("private");', '123'),
        throwsA(isA<CoreError>()),
      );
    }
    await expectLater(
      DouyuSign.getSign(
        'function ub98484234() { return "x".repeat(70000); }',
        '1',
      ),
      throwsA(isA<CoreError>()),
    );
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    final context = RequestContext(timeout: const Duration(milliseconds: 150));
    try {
      await expectLater(
        context.run(() => DouyuSign.getSign('for (;;) {}', '1')),
        throwsA(
          isA<CoreError>().having((e) => e.kind, 'kind', CoreErrorKind.timeout),
        ),
      );
      expect(ticks, greaterThan(0));
    } finally {
      timer.cancel();
    }
  });

  test(
    'Douyin signing passes quoted arguments and releases budget failures',
    () async {
      final signed = Uri.parse(
        DouyinSign.getAbogusUrl(
          'https://example.com/?keyword=quote\'value',
          "Mozilla/5.0 O'Reilly",
        ),
      );
      expect(signed.queryParameters['keyword'], "quote'value");
      expect(signed.queryParameters['a_bogus'], isNotEmpty);
      for (var attempt = 0; attempt < 3; attempt++) {
        final context = RequestContext(
          timeout: const Duration(milliseconds: 1),
        );
        await expectLater(
          context.run(() async => DouyinSign.getSignature('1', '2')),
          throwsA(
            isA<CoreError>().having(
              (error) => error.kind,
              'kind',
              CoreErrorKind.timeout,
            ),
          ),
        );
      }
      expect(DouyinSign.getSignature('1', '2'), isNotEmpty);
    },
  );
}
