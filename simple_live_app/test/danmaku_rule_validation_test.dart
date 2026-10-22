import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/danmaku_rule_validation.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show validateShieldRules;

void main() {
  test(
    'manual rules preserve ECMAScript features and reject malformed rules',
    () async {
      expect(await validateDanmakuRule('/(?<=hello)(world)\\1/'), isNull);
      expect(await validateDanmakuRule('/[unterminated/'), isNotNull);
      expect(await validateDanmakuRule('ordinary [literal'), isNull);
      expect(await validateDanmakuRule('x' * 4097), isNotNull);
      expect(await validateDanmakuRule('   '), isNotNull);
    },
  );
  test('import limits share native count, UTF-16 and total text budgets', () {
    expect(validateShieldRules(['/legacy [regex/', 'literal', 'literal']), [
      '/legacy [regex/',
      'literal',
    ]);
    expect(() => validateShieldRules(['valid', 1]), throwsFormatException);
    expect(() => validateShieldRules(['x' * 4097]), throwsFormatException);
    expect(
      () => validateShieldRules(List.generate(2001, (i) => 'rule-$i')),
      throwsFormatException,
    );
    expect(
      () => validateShieldRules(
        List.generate(
          129,
          (i) => '${i.toString().padLeft(4, '0')}${'x' * 4092}',
        ),
      ),
      throwsFormatException,
    );
    expect(validateShieldRules(['/${'x' * 4096}/']).single.length, 4098);
  });
}
