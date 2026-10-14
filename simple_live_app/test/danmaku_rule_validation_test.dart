import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/danmaku_rule_validation.dart';

void main() {
  test('manual rules preserve ECMAScript features and reject malformed rules',
      () async {
    expect(await validateDanmakuRule('/(?<=hello)(world)\\1/'), isNull);
    expect(await validateDanmakuRule('/[unterminated/'), isNotNull);
    expect(await validateDanmakuRule('ordinary [literal'), isNull);
    expect(await validateDanmakuRule('x' * 4097), isNotNull);
    expect(await validateDanmakuRule('   '), isNotNull);
  });
}
