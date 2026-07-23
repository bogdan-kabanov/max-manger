/// Which account is (was) a member of which group chat.
class AccountGroupMembership {
  const AccountGroupMembership({
    required this.accountId,
    required this.chatId,
    this.title = '',
    this.joinedAt,
    this.lastVerifiedAt,
  });

  final String accountId;
  final String chatId;
  final String title;
  final DateTime? joinedAt;
  final DateTime? lastVerifiedAt;

  String get key => '$accountId::$chatId';

  AccountGroupMembership copyWith({
    String? title,
    DateTime? joinedAt,
    DateTime? lastVerifiedAt,
  }) {
    return AccountGroupMembership(
      accountId: accountId,
      chatId: chatId,
      title: title ?? this.title,
      joinedAt: joinedAt ?? this.joinedAt,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'chatId': chatId,
        if (title.trim().isNotEmpty) 'title': title,
        if (joinedAt != null) 'joinedAt': joinedAt!.toIso8601String(),
        if (lastVerifiedAt != null) 'lastVerifiedAt': lastVerifiedAt!.toIso8601String(),
      };

  factory AccountGroupMembership.fromJson(Map<String, dynamic> json) {
    return AccountGroupMembership(
      accountId: json['accountId']?.toString() ?? '',
      chatId: json['chatId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      joinedAt: json['joinedAt'] != null
          ? DateTime.tryParse(json['joinedAt'].toString())
          : null,
      lastVerifiedAt: json['lastVerifiedAt'] != null
          ? DateTime.tryParse(json['lastVerifiedAt'].toString())
          : null,
    );
  }
}

class MembershipVerifyRow {
  const MembershipVerifyRow({
    required this.accountId,
    required this.accountLabel,
    required this.presentChatIds,
    required this.missingChatIds,
    this.error,
  });

  final String accountId;
  final String accountLabel;
  final Set<String> presentChatIds;
  final Set<String> missingChatIds;
  final String? error;

  bool get ok => error == null && missingChatIds.isEmpty;
}

class MembershipVerifySummary {
  const MembershipVerifySummary({
    required this.rows,
    required this.checked,
    required this.missingTotal,
  });

  final List<MembershipVerifyRow> rows;
  final int checked;
  final int missingTotal;

  bool get allOk => missingTotal == 0 && rows.every((r) => r.error == null);
}
