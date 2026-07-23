import 'package:flutter_test/flutter_test.dart';

import 'package:max_desktop/models/account_isolation.dart';
import 'package:max_desktop/models/account_map_state.dart';
import 'package:max_desktop/models/max_account.dart';
import 'package:max_desktop/models/max_channel_catalog_entry.dart';
import 'package:max_desktop/services/pipeline_group_planner.dart';

MaxAccount _acc(String id, {String? token}) => MaxAccount(
      id: id,
      label: id,
      createdAt: DateTime(2024),
      isolation: ProfileFingerprint.generate(id),
      apiToken: token,
    );

void main() {
  test('splits assigned groups evenly across children', () {
    final mother = _acc('m1', token: 't');
    final c1 = _acc('c1', token: 't');
    final c2 = _acc('c2', token: 't');
    final cluster = MotherCluster(
      id: 'cl1',
      name: 'Cluster',
      motherAccountId: mother.id,
      childAccountIds: {c1.id, c2.id},
    );
    final catalog = [
      for (var i = 0; i < 10; i++)
        MaxChannelCatalogEntry(
          chatId: 'chat-$i',
          title: 'G$i',
          inviteHash: 'invitelink$hash$i'.padRight(12, 'x'),
          assignedMotherAccountId: mother.id,
        ),
    ];

    final plan = PipelineGroupPlanner.build(
      clusters: [cluster],
      accounts: [mother, c1, c2],
      catalog: catalog,
    );

    expect(plan.ok, isTrue);
    expect(plan.slots.length, 2);
    expect(plan.totalGroups, 10);
    expect(plan.slots[0].groupCount + plan.slots[1].groupCount, 10);
    expect(plan.slots[0].groupCount, 5);
    expect(plan.slots[1].groupCount, 5);
    final allIds = {
      for (final s in plan.slots)
        for (final g in s.groups) g.chatId,
    };
    expect(allIds.length, 10);
  });
}
