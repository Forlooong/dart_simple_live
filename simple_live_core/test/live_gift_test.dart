import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  test('combo increments and cumulative totals use separate rules', () {
    const first = LiveGiftMessage('观众', '鲜花', 2, 'combo');
    const next = LiveGiftMessage('观众', '鲜花', 3, 'combo');
    expect(first.mergeCombo(next).quantity, 5);
    const reported = LiveGiftMessage('观众', '鲜花', 3, 'combo', cumulative: true);
    expect(first.mergeCombo(reported).quantity, 3);
    expect(reported.mergeCombo(first).quantity, 5);
    expect(reported.mergeCombo(reported).quantity, 3);
  });

  test('missing gift names keep the platform item ID', () {
    const raw = LiveGiftMessage('观众', '', 1, '', itemId: 20206);
    expect(raw.description, '观众 赠送 礼物 #20206 ×1');
    expect(raw.withName('荧光棒').description, '观众 赠送 荧光棒 ×1');
  });
}
