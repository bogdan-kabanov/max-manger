import '../models/account_map_state.dart';
import '../models/max_account.dart';
import '../models/mother_group_channel.dart';

/// One invite batch: these children go into one mother group.
class MotherInviteSlot {
  const MotherInviteSlot({
    required this.clusterId,
    required this.clusterName,
    required this.mother,
    required this.group,
    required this.children,
  });

  final String clusterId;
  final String clusterName;
  final MaxAccount mother;
  final MotherGroupChannel group;
  final List<MaxAccount> children;

  int get inviteCount => children.length;
}

class MotherInviteMotherSummary {
  const MotherInviteMotherSummary({
    required this.clusterId,
    required this.clusterName,
    required this.mother,
    required this.accountCount,
    required this.groupCount,
    required this.inviteCount,
    required this.children,
  });

  final String clusterId;
  final String clusterName;
  final MaxAccount mother;
  final int accountCount;
  final int groupCount;
  final int inviteCount;
  final List<MaxAccount> children;
}

/// Proportional uzb → mothers (≤[invitesPerMother]) → groups.
class MotherInvitePlan {
  const MotherInvitePlan({
    required this.slots,
    required this.motherSummaries,
    required this.uzbekTotal,
    required this.uzbekAssigned,
    required this.uzbekSkipped,
    required this.invitesPerMother,
    required this.mothersReady,
    required this.mothersWithoutGroups,
    required this.uzbekWithoutViewerId,
    this.error,
  });

  final List<MotherInviteSlot> slots;
  final List<MotherInviteMotherSummary> motherSummaries;
  final int uzbekTotal;
  final int uzbekAssigned;
  final int uzbekSkipped;
  final int invitesPerMother;
  final int mothersReady;
  final int mothersWithoutGroups;
  final int uzbekWithoutViewerId;
  final String? error;

  int get totalInvites => slots.fold(0, (sum, s) => sum + s.inviteCount);
  int get capacity => mothersReady * invitesPerMother;
  bool get isEmpty => slots.isEmpty;
  bool get ok => error == null && slots.isNotEmpty;

  String get summaryLine {
    if (error != null) return error!;
    return 'Маток: $mothersReady · Узб: $uzbekTotal → в план: $uzbekAssigned'
        ' (лимит $invitesPerMother/матка, ёмкость $capacity)'
        '${uzbekSkipped > 0 ? ' · не влезло: $uzbekSkipped' : ''}'
        '${uzbekWithoutViewerId > 0 ? ' · без id: $uzbekWithoutViewerId' : ''}';
  }
}

class MotherInvitePlanner {
  static const defaultInvitesPerMother = 100;

  /// Split [items] into [bucketCount] lists as evenly as possible.
  static List<List<T>> splitEvenly<T>(List<T> items, int bucketCount) {
    if (bucketCount <= 0) return const [];
    if (items.isEmpty) return List.generate(bucketCount, (_) => <T>[]);
    final result = List.generate(bucketCount, (_) => <T>[]);
    for (var i = 0; i < items.length; i++) {
      result[i % bucketCount].add(items[i]);
    }
    return result;
  }

  /// Split into [bucketCount] chunks, each at most [cap] items. Leftover dropped.
  static List<List<T>> splitEvenlyCapped<T>(List<T> items, int bucketCount, int cap) {
    if (bucketCount <= 0) return const [];
    final capacity = bucketCount * cap;
    final take = items.length > capacity ? items.sublist(0, capacity) : items;
    if (take.isEmpty) return List.generate(bucketCount, (_) => <T>[]);

    final base = take.length ~/ bucketCount;
    final extra = take.length % bucketCount;
    final result = <List<T>>[];
    var offset = 0;
    for (var i = 0; i < bucketCount; i++) {
      final size = (base + (i < extra ? 1 : 0)).clamp(0, cap);
      result.add(take.sublist(offset, offset + size));
      offset += size;
    }
    return result;
  }

  static MotherInvitePlan build({
    required List<MotherCluster> clusters,
    required List<MaxAccount> accounts,
    required Map<String, List<MotherGroupChannel>> groupsByMotherId,
    int invitesPerMother = defaultInvitesPerMother,
  }) {
    final byId = {for (final a in accounts) a.id: a};
    final ready = <({MotherCluster cluster, MaxAccount mother, List<MotherGroupChannel> groups})>[];
    var withoutGroups = 0;

    for (final cluster in clusters) {
      final motherId = cluster.motherAccountId;
      if (motherId == null) continue;
      final mother = byId[motherId];
      if (mother == null || !mother.hasApiSession) continue;
      final groups = groupsByMotherId[motherId] ?? const <MotherGroupChannel>[];
      if (groups.isEmpty) {
        withoutGroups++;
        continue;
      }
      ready.add((cluster: cluster, mother: mother, groups: groups));
    }

    if (ready.isEmpty) {
      return MotherInvitePlan(
        slots: const [],
        motherSummaries: const [],
        uzbekTotal: 0,
        uzbekAssigned: 0,
        uzbekSkipped: 0,
        invitesPerMother: invitesPerMother,
        mothersReady: 0,
        mothersWithoutGroups: withoutGroups,
        uzbekWithoutViewerId: 0,
        error: withoutGroups > 0
            ? 'Сначала загрузите каналы маток'
            : 'Нет готовых маток (нужен токен и каналы)',
      );
    }

    final motherIds = ready.map((r) => r.mother.id).toSet();
    final uzbekAll = accounts.where((a) => !motherIds.contains(a.id) && a.isUzbek).toList();
    final uzbekReady = uzbekAll.where((a) => a.viewerId != null).toList();
    final withoutViewer = uzbekAll.length - uzbekReady.length;

    if (uzbekReady.isEmpty) {
      return MotherInvitePlan(
        slots: const [],
        motherSummaries: const [],
        uzbekTotal: uzbekAll.length,
        uzbekAssigned: 0,
        uzbekSkipped: 0,
        invitesPerMother: invitesPerMother,
        mothersReady: ready.length,
        mothersWithoutGroups: withoutGroups,
        uzbekWithoutViewerId: withoutViewer,
        error: uzbekAll.isEmpty
            ? 'Нет узб-аккаунтов (+998 или «узб» в названии)'
            : 'У узб-аккаунтов нет viewer id — откройте их и возьмите токен',
      );
    }

    final chunks = splitEvenlyCapped(uzbekReady, ready.length, invitesPerMother);
    final assigned = chunks.fold<int>(0, (s, c) => s + c.length);
    final skipped = uzbekReady.length - assigned;

    final slots = <MotherInviteSlot>[];
    final summaries = <MotherInviteMotherSummary>[];

    for (var i = 0; i < ready.length; i++) {
      final row = ready[i];
      final children = chunks[i];
      if (children.isEmpty) {
        summaries.add(
          MotherInviteMotherSummary(
            clusterId: row.cluster.id,
            clusterName: row.cluster.name,
            mother: row.mother,
            accountCount: 0,
            groupCount: row.groups.length,
            inviteCount: 0,
            children: const [],
          ),
        );
        continue;
      }

      final perGroup = splitEvenly(children, row.groups.length);
      var inviteCount = 0;
      for (var g = 0; g < row.groups.length; g++) {
        final batch = perGroup[g];
        if (batch.isEmpty) continue;
        inviteCount += batch.length;
        slots.add(
          MotherInviteSlot(
            clusterId: row.cluster.id,
            clusterName: row.cluster.name,
            mother: row.mother,
            group: row.groups[g],
            children: batch,
          ),
        );
      }

      summaries.add(
        MotherInviteMotherSummary(
          clusterId: row.cluster.id,
          clusterName: row.cluster.name,
          mother: row.mother,
          accountCount: children.length,
          groupCount: row.groups.length,
          inviteCount: inviteCount,
          children: children,
        ),
      );
    }

    return MotherInvitePlan(
      slots: slots,
      motherSummaries: summaries,
      uzbekTotal: uzbekAll.length,
      uzbekAssigned: assigned,
      uzbekSkipped: skipped,
      invitesPerMother: invitesPerMother,
      mothersReady: ready.length,
      mothersWithoutGroups: withoutGroups,
      uzbekWithoutViewerId: withoutViewer,
    );
  }
}
