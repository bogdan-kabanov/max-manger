class MotherGroupChannel {
  const MotherGroupChannel({
    required this.chatId,
    required this.title,
    this.type,
    this.inviteHash,
    this.updatedAt,
  });

  final String chatId;
  final String title;
  final String? type;
  final String? inviteHash;
  final DateTime? updatedAt;

  static bool isValidInviteHash(String? hash) {
    if (hash == null) return false;
    final h = hash.trim();
    if (h.isEmpty || h == 'undefined' || h == 'null') return false;
    return RegExp(r'^[A-Za-z0-9_-]{8,}$').hasMatch(h);
  }

  String? get inviteUrl =>
      hasInviteLink ? 'https://max.ru/join/$inviteHash' : null;

  bool get hasInviteLink => isValidInviteHash(inviteHash);

  String get deliveryLabel => hasInviteLink ? 'по ссылке' : 'добавить по ID';

  MotherGroupChannel copyWith({
    String? title,
    String? type,
    String? inviteHash,
    DateTime? updatedAt,
    bool clearInviteHash = false,
  }) {
    return MotherGroupChannel(
      chatId: chatId,
      title: title ?? this.title,
      type: type ?? this.type,
      inviteHash: clearInviteHash ? null : (inviteHash ?? this.inviteHash),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'chatId': chatId,
        'title': title,
        if (type != null) 'type': type,
        if (inviteHash != null) 'inviteHash': inviteHash,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  factory MotherGroupChannel.fromJson(Map<String, dynamic> json) {
    return MotherGroupChannel(
      chatId: json['chatId']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Без названия',
      type: json['type']?.toString(),
      inviteHash: json['inviteHash']?.toString(),
      updatedAt: json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt'].toString()) : null,
    );
  }

  static List<MotherGroupChannel> mergeLists(
    List<MotherGroupChannel> existing,
    List<MotherGroupChannel> incoming,
  ) {
    final byId = {for (final g in existing) g.chatId: g};
    for (final group in incoming) {
      final prev = byId[group.chatId];
      if (prev == null) {
        byId[group.chatId] = group;
        continue;
      }
      byId[group.chatId] = MotherGroupChannel(
        chatId: group.chatId,
        title: group.title.isNotEmpty ? group.title : prev.title,
        type: group.type ?? prev.type,
        inviteHash: group.inviteHash ?? prev.inviteHash,
        updatedAt: group.updatedAt ?? prev.updatedAt ?? DateTime.now(),
      );
    }
    final merged = byId.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return merged;
  }
}
