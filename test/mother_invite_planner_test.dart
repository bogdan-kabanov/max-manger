import 'package:flutter_test/flutter_test.dart';

import 'package:max_desktop/models/account_isolation.dart';
import 'package:max_desktop/models/account_map_state.dart';
import 'package:max_desktop/models/max_account.dart';
import 'package:max_desktop/models/mother_group_channel.dart';
import 'package:max_desktop/services/mother_invite_planner.dart';

MaxAccount _acc({
  required String id,
  required String label,
  String? phone,
  int? viewerId,
  String? token,
}) {
  return MaxAccount(
    id: id,
    label: label,
    createdAt: DateTime(2026),
    isolation: ProfileFingerprint.generate(id),
    phone: phone,
    viewerId: viewerId,
    apiToken: token,
  );
}

void main() {
  test('splitEvenlyCapped respects 100 per mother', () {
    final items = List.generate(350, (i) => i);
    final chunks = MotherInvitePlanner.splitEvenlyCapped(items, 3, 100);
    expect(chunks.length, 3);
    expect(chunks.every((c) => c.length <= 100), isTrue);
    expect(chunks.fold<int>(0, (s, c) => s + c.length), 300);
  });

  test('plan distributes uzb across mothers and groups', () {
    final mothers = [
      _acc(id: 'm1', label: 'M1', token: 't1', viewerId: 1),
      _acc(id: 'm2', label: 'M2', token: 't2', viewerId: 2),
    ];
    final uzb = List.generate(
      20,
      (i) => _acc(id: 'u$i', label: 'узб $i', phone: '9989012345${i.toString().padLeft(2, '0')}', viewerId: 100 + i),
    );
    final clusters = [
      MotherCluster(id: 'c1', name: 'Матка 1', motherAccountId: 'm1'),
      MotherCluster(id: 'c2', name: 'Матка 2', motherAccountId: 'm2'),
    ];
    final groups = {
      'm1': [
        const MotherGroupChannel(chatId: 'g1', title: 'G1'),
        const MotherGroupChannel(chatId: 'g2', title: 'G2'),
      ],
      'm2': [
        const MotherGroupChannel(chatId: 'g3', title: 'G3'),
        const MotherGroupChannel(chatId: 'g4', title: 'G4'),
      ],
    };

    final plan = MotherInvitePlanner.build(
      clusters: clusters,
      accounts: [...mothers, ...uzb],
      groupsByMotherId: groups,
      invitesPerMother: 100,
    );

    expect(plan.ok, isTrue);
    expect(plan.uzbekAssigned, 20);
    expect(plan.mothersReady, 2);
    expect(plan.motherSummaries.every((s) => s.accountCount == 10), isTrue);
    // 10 accounts / 2 groups = 5 each
    expect(plan.slots.every((s) => s.inviteCount == 5), isTrue);
    expect(plan.totalInvites, 20);
  });

  test('caps at 100 per mother when uzb overflow', () {
    final mother = _acc(id: 'm1', label: 'M1', token: 't', viewerId: 1);
    final uzb = List.generate(
      150,
      (i) => _acc(id: 'u$i', label: 'uzb$i', phone: '99890${(1000000 + i)}', viewerId: 10 + i),
    );
    final plan = MotherInvitePlanner.build(
      clusters: [MotherCluster(id: 'c1', name: 'M', motherAccountId: 'm1')],
      accounts: [mother, ...uzb],
      groupsByMotherId: {
        'm1': [const MotherGroupChannel(chatId: 'g1', title: 'G')],
      },
      invitesPerMother: 100,
    );
    expect(plan.uzbekAssigned, 100);
    expect(plan.uzbekSkipped, 50);
    expect(plan.totalInvites, 100);
  });
}
