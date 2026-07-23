import 'package:uuid/uuid.dart';

enum PipelineJournalKind {
  assign,
  unassign,
  launchPlan,
  joinLink,
  joinById,
  templateOnJoin,
  templateDaily,
  funnel,
  info,
  warn,
  error;

  String get label => switch (this) {
        assign => 'Назначение',
        unassign => 'Снятие',
        launchPlan => 'План запуска',
        joinLink => 'Вступление по ссылке',
        joinById => 'Добавление по ID',
        templateOnJoin => 'Шаблон после входа',
        templateDaily => 'Шаблон по расписанию',
        funnel => 'Воронка',
        info => 'Инфо',
        warn => 'Внимание',
        error => 'Ошибка',
      };

  static PipelineJournalKind fromJson(String? raw) {
    for (final v in PipelineJournalKind.values) {
      if (v.name == raw) return v;
    }
    return PipelineJournalKind.info;
  }
}

class PipelineJournalEvent {
  const PipelineJournalEvent({
    required this.id,
    required this.at,
    required this.kind,
    required this.message,
    this.motherAccountId,
    this.childAccountId,
    this.chatId,
    this.detail,
  });

  final String id;
  final DateTime at;
  final PipelineJournalKind kind;
  final String message;
  final String? motherAccountId;
  final String? childAccountId;
  final String? chatId;
  final String? detail;

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'kind': kind.name,
        'message': message,
        if (motherAccountId != null) 'motherAccountId': motherAccountId,
        if (childAccountId != null) 'childAccountId': childAccountId,
        if (chatId != null) 'chatId': chatId,
        if (detail != null) 'detail': detail,
      };

  factory PipelineJournalEvent.fromJson(Map<String, dynamic> json) {
    return PipelineJournalEvent(
      id: json['id']?.toString() ?? const Uuid().v4(),
      at: DateTime.tryParse(json['at']?.toString() ?? '') ?? DateTime.now(),
      kind: PipelineJournalKind.fromJson(json['kind']?.toString()),
      message: json['message']?.toString() ?? '',
      motherAccountId: json['motherAccountId']?.toString(),
      childAccountId: json['childAccountId']?.toString(),
      chatId: json['chatId']?.toString(),
      detail: json['detail']?.toString(),
    );
  }

  static PipelineJournalEvent create({
    required PipelineJournalKind kind,
    required String message,
    String? motherAccountId,
    String? childAccountId,
    String? chatId,
    String? detail,
  }) {
    return PipelineJournalEvent(
      id: const Uuid().v4(),
      at: DateTime.now(),
      kind: kind,
      message: message,
      motherAccountId: motherAccountId,
      childAccountId: childAccountId,
      chatId: chatId,
      detail: detail,
    );
  }
}
