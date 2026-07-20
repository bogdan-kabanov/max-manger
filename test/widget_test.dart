import 'package:flutter_test/flutter_test.dart';
import 'package:max_desktop/models/account_isolation.dart';
import 'package:max_desktop/models/automation_rule.dart';
import 'package:max_desktop/models/max_account.dart';

void main() {
  test('MaxAccount serializes to json', () {
    final account = MaxAccount(
      id: '1',
      label: 'Test',
      createdAt: DateTime.parse('2026-01-01T00:00:00.000Z'),
      isolation: ProfileFingerprint.generate('1'),
    );

    final restored = MaxAccount.fromJson(account.toJson());
    expect(restored.id, '1');
    expect(restored.label, 'Test');
  });

  test('AutomationRule serializes to json', () {
    final rule = AutomationRule(
      id: '1',
      accountId: 'acc',
      name: 'Price',
      type: AutomationRuleType.keywordReply,
      enabled: true,
      keywords: ['цена'],
      replyText: '1000 руб',
    );

    final restored = AutomationRule.fromJson(rule.toJson());
    expect(restored.keywords, ['цена']);
    expect(restored.replyText, '1000 руб');
  });
}
