/// How template broadcast picks target chats relative to prior successful sends.
enum TemplateSendScope {
  /// Skip chats where this template was already sent (default).
  freshOnly,

  /// Only chats where this template was already sent (re-mail).
  alreadySentOnly,

  /// Ignore history — write to every channel.
  all,
}

extension TemplateSendScopeLabel on TemplateSendScope {
  String get title => switch (this) {
        TemplateSendScope.freshOnly => 'Только новые',
        TemplateSendScope.alreadySentOnly => 'Только уже слали',
        TemplateSendScope.all => 'Все каналы',
      };

  String get subtitle => switch (this) {
        TemplateSendScope.freshOnly => 'Пропустить каналы, куда этот шаблон уже уходил',
        TemplateSendScope.alreadySentOnly => 'Повторить только по каналам из истории отправок',
        TemplateSendScope.all => 'Слать везде, игнорируя историю',
      };
}
