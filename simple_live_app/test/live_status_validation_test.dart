import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/src/common/live_status_parser.dart';

void main() {
  group('LiveStatusParser', () {
    test('Bilibili distinguishes live, offline, and replay', () {
      for (final code in [0, 1, 2]) {
        expect(
          LiveStatusParser.bilibili({
            'data': {'live_status': code},
          }),
          code == 1,
        );
      }
    });

    test('Douyu live requires a valid non-replay flag', () {
      expect(
        LiveStatusParser.douyu({'show_status': 1, 'videoLoop': 0}),
        isTrue,
      );
      expect(
        LiveStatusParser.douyu({'show_status': 1, 'videoLoop': 1}),
        isFalse,
      );
      for (final videoLoop in [null, '0', false, 0.0, -1, 2]) {
        expect(
          () => LiveStatusParser.douyu({
            'show_status': 1,
            'videoLoop': videoLoop,
          }),
          throwsFormatException,
        );
      }
    });

    test('Douyu offline does not require playback metadata', () {
      for (final code in [0, 2]) {
        expect(LiveStatusParser.douyu({'show_status': code}), isFalse);
      }
    });

    test('Huya preserves integer live and offline states', () {
      for (final code in [0, 1, 2, 4]) {
        expect(
          LiveStatusParser.huya({
            'roomInfo': {'eLiveStatus': code},
          }),
          code == 2,
        );
      }
    });

    test('Douyin preserves status 4 for stable room ID fallback', () {
      for (final code in [0, 1, 2, 3, 4]) {
        expect(LiveStatusParser.douyinStatusCode({'status': code}), code);
      }
    });

    test('Malformed response containers never become offline', () {
      for (final response in [null, <String, Object?>{}, [], 'error', false]) {
        expect(
          () => LiveStatusParser.bilibili(response),
          throwsFormatException,
        );
        expect(
          () => LiveStatusParser.douyu(response),
          throwsFormatException,
        );
        expect(
          () => LiveStatusParser.huya(response),
          throwsFormatException,
        );
        expect(
          () => LiveStatusParser.douyinStatusCode(response),
          throwsFormatException,
        );
      }
    });

    test('Missing and invalid status fields never become offline', () {
      for (final status in [null, '0', '1', '2', false, 0.0, 1.5, -1, [], {}]) {
        expect(
          () => LiveStatusParser.bilibili({
            'data': {'live_status': status},
          }),
          throwsFormatException,
        );
        expect(
          () => LiveStatusParser.douyu({'show_status': status, 'videoLoop': 0}),
          throwsFormatException,
        );
        expect(
          () => LiveStatusParser.huya({
            'roomInfo': {'eLiveStatus': status},
          }),
          throwsFormatException,
        );
        expect(
          () => LiveStatusParser.douyinStatusCode({'status': status}),
          throwsFormatException,
        );
      }
    });
  });
}
