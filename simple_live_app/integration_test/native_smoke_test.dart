import 'dart:convert';
import 'dart:typed_data';

import 'package:danmaku_native/danmaku_native.dart';
import 'package:dart_quickjs/controlled_regex.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('packaged native decoder, filter and ECMAScript interrupt work',
      (tester) async {
    final decoder = await NativeWorker.start(1);
    final filter = await NativeWorker.start(0, filtering: true);
    try {
      final encoded = await decoder.call(
          'encode',
          encodeWire({
            'v': 1,
            'kind': 'bili',
            'operation': 5,
            'text': utf16Bytes(jsonEncode({
              'cmd': 'DANMU_MSG',
              'info': [
                [0, 0, 0, 0xffffff],
                '你好😀',
                [1, '用户']
              ],
            })),
          }));
      final decoded =
          await decoder.call('decode', encoded['wire'] as Uint8List);
      expect(utf16String((decoded['events'] as List).single['text']), '你好😀');
      await filter.call(
          'rules',
          encodeWire({
            'v': 1,
            'version': 1,
            'rules': [
              {'regex': true, 'text': utf16Bytes(r'a(?=b)')}
            ],
          }));
      final filtered = await filter.call(
          'filter',
          encodeWire({
            'v': 1,
            'version': 1,
            'texts': ['ab', 'ac', '😀'].map(utf16Bytes).toList(),
          }));
      expect(filtered['keep'], [false, true, true]);
    } finally {
      await decoder.close();
      await filter.close();
    }
    final surrogate = String.fromCharCode(0xd800);
    final exact = ControlledRegex([surrogate]);
    try {
      expect(exact.keep([surrogate, '�']), [false, true]);
    } finally {
      exact.dispose();
    }
    final expensive = ControlledRegex([r'^(a+)+$']);
    try {
      expect(() => expensive.keep(['${'a' * 10000}!']), throwsStateError);
    } finally {
      expensive.dispose();
    }
  });
}
