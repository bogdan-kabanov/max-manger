import '../models/account_map_state.dart';
import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import 'mother_invite_planner.dart';

/// One child gets these catalog groups (unique across siblings).
class PipelineAssignSlot {
  const PipelineAssignSlot({
    required this.clusterId,
    required this.clusterName,
    required this.mother,
    required this.child,
    required this.groups,
  });

  final String clusterId;
  final String clusterName;
  final MaxAccount mother;
  final MaxAccount child;
  final List<MaxChannelCatalogEntry> groups;

  int get groupCount => groups.length;
  int get withLinkCount => groups.where((g) => g.hasInviteLink).length;
  int get withoutLinkCount => groupCount - withLinkCount;
}

class PipelineMotherSummary {
  const PipelineMotherSummary({
    required this.clusterId,
    required this.clusterName,
    required this.mother,
    required this.children,
    required this.groupCount,
    required this.withLinkCount,
    required this.withoutLinkCount,
  });

  final String clusterId;
  final String clusterName;
  final MaxAccount mother;
  final List<MaxAccount> children;
  final int groupCount;
  final int withLinkCount;
  final int withoutLinkCount;
}

class PipelineLaunchPlan {
  const PipelineLaunchPlan({
    required this.slots,
    required this.motherSummaries,
    this.error,
  });

  final List<PipelineAssignSlot> slots;
  final List<PipelineMotherSummary> motherSummaries;
  final String? error;

  bool get isEmpty => slots.isEmpty;
  bool get ok => error == null && slots.isNotEmpty;

  int get totalGroups => slots.fold(0, (s, e) => s + e.groupCount);
  int get totalWithLink => slots.fold(0, (s, e) => s + e.withLinkCount);
  int get totalWithoutLink => slots.fold(0, (s, e) => s + e.withoutLinkCount);
  int get childCount => slots.length;

  /// Все слоты — соло (воркер = матка, дочек нет).
  bool get isSoloWorkers =>
      slots.isNotEmpty && slots.every((s) => s.child.id == s.mother.id);

  String get summaryLine {
    if (error != null) return error!;
    final who = isSoloWorkers ? 'Аккаунтов' : 'Дочек';
    return '$who: $childCount · групп: $totalGroups'
        ' (со ссылкой: $totalWithLink'
        '${totalWithoutLink > 0 ? ', без ссылки: $totalWithoutLink' : ''})';
  }
}

/// Evenly split each matka's assigned catalog groups across her children.
class PipelineGroupPlanner {
  static PipelineLaunchPlan build({
    required List<MotherCluster> clusters,
    required List<MaxAccount> accounts,
    required List<MaxChannelCatalogEntry> catalog,
    /// chatIds already joined by any child of the same matka — skip them.
    Set<String> alreadyJoinedChatIds = const {},
  }) {
    final byId = {for (final a in accounts) a.id: a};
    final slots = <PipelineAssignSlot>[];
    final summaries = <PipelineMotherSummary>[];

    for (final cluster in clusters) {
      final motherId = cluster.motherAccountId;
      if (motherId == null) continue;
      final mother = byId[motherId];
      if (mother == null || !mother.hasApiSession) continue;

      final children = <MaxAccount>[];
      for (final childId in cluster.childAccountIds) {
        final child = byId[childId];
        if (child != null && child.hasApiSession) children.add(child);
      }
      // Соло-матка без дочек: сама вступает в назначенные группы.
      final workers = children.isNotEmpty ? children : [mother];

      final groups = catalog
          .where((e) => e.assignedMotherAccountId == motherId)
          .where((e) => !alreadyJoinedChatIds.contains(e.chatId))
          .toList();
      if (groups.isEmpty) continue;

      final buckets = MotherInvitePlanner.splitEvenly(groups, workers.length);
      for (var i = 0; i < workers.length; i++) {
        final bucket = buckets[i];
        if (bucket.isEmpty) continue;
        slots.add(
          PipelineAssignSlot(
            clusterId: cluster.id,
            clusterName: cluster.name,
            mother: mother,
            child: workers[i],
            groups: bucket,
          ),
        );
      }

      summaries.add(
        PipelineMotherSummary(
          clusterId: cluster.id,
          clusterName: cluster.name,
          mother: mother,
          children: workers,
          groupCount: groups.length,
          withLinkCount: groups.where((g) => g.hasInviteLink).length,
          withoutLinkCount: groups.where((g) => !g.hasInviteLink).length,
        ),
      );
    }

    if (slots.isEmpty) {
      final hasSolo = clusters.any((c) => c.childAccountIds.isEmpty && c.motherAccountId != null);
      return PipelineLaunchPlan(
        slots: const [],
        motherSummaries: const [],
        error: hasSolo
            ? 'Нет групп для вступления (назначьте родителю или уже всё вступили)'
            : 'Нет назначенных групп со свободными дочками (с токеном)',
      );
    }

    return PipelineLaunchPlan(slots: slots, motherSummaries: summaries);
  }
}
