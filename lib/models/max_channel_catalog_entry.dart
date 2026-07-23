import 'mother_group_channel.dart';

class MaxChannelCatalogEntry {
  const MaxChannelCatalogEntry({
    required this.chatId,
    required this.title,
    this.type,
    this.inviteHash,
    this.topic,
    this.source,
    this.discoveredAt,
    this.assignedMotherAccountId,
  });

  final String chatId;
  final String title;
  final String? type;
  final String? inviteHash;
  final String? topic;
  final String? source;
  final DateTime? discoveredAt;

  /// Soft assignment: which matka owns this group before any join.
  final String? assignedMotherAccountId;

  bool get hasInviteLink => MotherGroupChannel.isValidInviteHash(inviteHash);

  String? get inviteUrl => hasInviteLink ? 'https://max.ru/join/$inviteHash' : null;

  bool get isAssigned =>
      assignedMotherAccountId != null && assignedMotherAccountId!.trim().isNotEmpty;

  MaxChannelCatalogEntry copyWith({
    String? title,
    String? type,
    String? inviteHash,
    String? topic,
    String? source,
    DateTime? discoveredAt,
    String? assignedMotherAccountId,
    bool clearAssignment = false,
  }) {
    return MaxChannelCatalogEntry(
      chatId: chatId,
      title: title ?? this.title,
      type: type ?? this.type,
      inviteHash: inviteHash ?? this.inviteHash,
      topic: topic ?? this.topic,
      source: source ?? this.source,
      discoveredAt: discoveredAt ?? this.discoveredAt,
      assignedMotherAccountId: clearAssignment
          ? null
          : (assignedMotherAccountId ?? this.assignedMotherAccountId),
    );
  }

  Map<String, dynamic> toJson() => {
        'chatId': chatId,
        'title': title,
        if (type != null) 'type': type,
        if (inviteHash != null) 'inviteHash': inviteHash,
        if (topic != null) 'topic': topic,
        if (source != null) 'source': source,
        if (discoveredAt != null) 'discoveredAt': discoveredAt!.toIso8601String(),
        if (assignedMotherAccountId != null)
          'assignedMotherAccountId': assignedMotherAccountId,
      };

  factory MaxChannelCatalogEntry.fromJson(Map<String, dynamic> json) {
    final assigned = json['assignedMotherAccountId']?.toString().trim();
    return MaxChannelCatalogEntry(
      chatId: json['chatId']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Без названия',
      type: json['type']?.toString(),
      inviteHash: json['inviteHash']?.toString(),
      topic: json['topic']?.toString(),
      source: json['source']?.toString(),
      discoveredAt:
          json['discoveredAt'] != null ? DateTime.tryParse(json['discoveredAt'].toString()) : null,
      assignedMotherAccountId: (assigned != null && assigned.isNotEmpty) ? assigned : null,
    );
  }

  factory MaxChannelCatalogEntry.fromCli(Map<String, dynamic> json, {String? topic}) {
    final rawHash = json['hash']?.toString() ?? json['inviteHash']?.toString();
    final hash = MotherGroupChannel.isValidInviteHash(rawHash) ? rawHash!.trim() : null;
    return MaxChannelCatalogEntry(
      chatId: json['chatId']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Без названия',
      type: json['type']?.toString(),
      inviteHash: hash,
      topic: topic ?? json['topic']?.toString(),
      source: json['source']?.toString(),
      discoveredAt: DateTime.now(),
    );
  }

  static List<MaxChannelCatalogEntry> mergeLists(
    List<MaxChannelCatalogEntry> existing,
    List<MaxChannelCatalogEntry> incoming,
  ) {
    final byId = {for (final e in existing) e.chatId: e};
    final byHash = <String, MaxChannelCatalogEntry>{
      for (final e in existing)
        if (e.hasInviteLink) e.inviteHash!: e,
    };

    for (final entry in incoming) {
      if (entry.chatId.isEmpty) continue;
      if (entry.hasInviteLink) {
        final hash = entry.inviteHash!.trim();
        final prevByHash = byHash[hash];
        if (prevByHash != null && prevByHash.chatId != entry.chatId) continue;
      }

      final prev = byId[entry.chatId];
      if (prev == null) {
        byId[entry.chatId] = entry;
        if (entry.hasInviteLink) byHash[entry.inviteHash!] = entry;
        continue;
      }

      byId[entry.chatId] = MaxChannelCatalogEntry(
        chatId: entry.chatId,
        title: entry.title.isNotEmpty ? entry.title : prev.title,
        type: entry.type ?? prev.type,
        inviteHash: entry.inviteHash ?? prev.inviteHash,
        topic: entry.topic ?? prev.topic,
        source: entry.source ?? prev.source,
        discoveredAt: entry.discoveredAt ?? prev.discoveredAt ?? DateTime.now(),
        // Preserve soft assignment unless incoming explicitly sets one.
        assignedMotherAccountId:
            entry.assignedMotherAccountId ?? prev.assignedMotherAccountId,
      );
      final merged = byId[entry.chatId]!;
      if (merged.hasInviteLink) byHash[merged.inviteHash!] = merged;
    }

    final merged = byId.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return merged;
  }
}
