import 'dart:convert';
import 'dart:typed_data';
import 'package:danmaku_native/danmaku_native.dart';
import 'package:dart_quickjs/controlled_regex.dart';
import 'package:test/test.dart';

void main() {
  test('CBOR preserves Dart UTF-16 units and rejects trailing input', () {
    final value = '中文😀${String.fromCharCode(0xd800)}';
    final wire = encodeWire({
      'v': 1,
      'text': utf16Bytes(value),
      'negative': -123,
    });
    expect(utf16String(decodeWire(wire)['text']).codeUnits, value.codeUnits);
    expect(decodeWire(wire)['negative'], -123);
    expect(
      () => decodeWire(Uint8List.fromList([...wire, 0])),
      throwsFormatException,
    );
  });

  test(
    'native packaged library roundtrip and one-in-flight worker guard',
    () async {
      final worker = await NativeWorker.start(1);
      try {
        final pending = worker.call(
          'encode',
          encodeWire({
            'v': 1,
            'kind': 'bili',
            'operation': 5,
            'text': utf16Bytes(
              jsonEncode({
                'cmd': 'DANMU_MSG',
                'info': [
                  [0, 0, 0, 0xffffff],
                  '你好😀',
                  [1, '用户'],
                ],
              }),
            ),
          }),
        );
        expect(() => worker.call('reset', Uint8List(0)), throwsStateError);
        final encoded = await pending;
        final decoded = await worker.call(
          'decode',
          encoded['wire'] as Uint8List,
        );
        final events = decoded['events'] as List;
        expect(events, hasLength(1));
        expect(utf16String(events.single['text']), '你好😀');
      } finally {
        await worker.close();
      }
    },
  );

  test('Rust and ECMAScript compatibility match Dart defaults', () async {
    final worker = await NativeWorker.start(0, filtering: true);
    final cases = <String, List<String>>{
      r'a(?=b)': ['ab', 'ac', 'a'],
      r'(a)\1': ['aa', 'ab', '😀aa'],
      r'(?<=a)b': ['ab', 'bb'],
      r'\b中文\b': ['中文', 'a中文b'],
      r'^.$': ['😀', 'a', '\n', String.fromCharCode(0xd800)],
      r'[\ud800-\udfff]': ['😀', 'a', String.fromCharCode(0xd800)],
      r'\141': ['a', '141', 'b'],
      r'\q': ['q', r'\q', 'a'],
      r'a$': ['a', 'a\n', 'a\r\n', 'aa'],
    };
    var version = 0;
    try {
      for (final entry in cases.entries) {
        await worker.call(
          'rules',
          encodeWire({
            'v': 1,
            'version': ++version,
            'rules': [
              {'regex': true, 'text': utf16Bytes(entry.key)},
            ],
          }),
        );
        final result = await worker.call(
          'filter',
          encodeWire({
            'v': 1,
            'version': version,
            'texts': entry.value.map(utf16Bytes).toList(),
          }),
        );
        expect(
          result['keep'],
          entry.value.map((text) => !RegExp(entry.key).hasMatch(text)).toList(),
          reason: entry.key,
        );
        final qjs = ControlledRegex([entry.key]);
        try {
          expect(qjs.keep(entry.value), result['keep'], reason: entry.key);
        } finally {
          qjs.dispose();
        }
      }
    } finally {
      await worker.close();
    }
  });

  test(
    'QuickJS actively interrupts pathological regex and preserves surrogates',
    () {
      final qjs = ControlledRegex([r'^(a+)+$']);
      try {
        final watch = Stopwatch()..start();
        expect(() => qjs.keep(['${'a' * 10000}!']), throwsStateError);
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      } finally {
        qjs.dispose();
      }
      final literal = String.fromCharCode(0xd800);
      final exact = ControlledRegex([literal]);
      try {
        expect(exact.keep([literal, '�']), [false, true]);
      } finally {
        exact.dispose();
      }
    },
  );

  test(
    'Rust budget quarantines once and valid rule replacement recovers',
    () async {
      final worker = await NativeWorker.start(0, filtering: true);
      try {
        await worker.call(
          'rules',
          encodeWire({
            'v': 1,
            'version': 1,
            'rules': [
              {'regex': true, 'text': utf16Bytes(r'^(a+)+$')},
            ],
          }),
        );
        final request = encodeWire({
          'v': 1,
          'version': 1,
          'texts': [utf16Bytes('${'a' * 100}!')],
        });
        final first = await worker.call('filter', request);
        expect(first['quarantined'], true);
        final next = await worker.call('filter', request);
        expect(next['keep'], [false]);
        expect(next['diagnostics'], isEmpty);
        await worker.call(
          'rules',
          encodeWire({'v': 1, 'version': 2, 'rules': []}),
        );
        expect(
          (await worker.call(
            'filter',
            encodeWire({
              'v': 1,
              'version': 2,
              'texts': [utf16Bytes('ok')],
            }),
          ))['keep'],
          [true],
        );
      } finally {
        await worker.close();
      }
    },
  );
}
