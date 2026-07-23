import 'dart:async';
import 'dart:io';

/// Cancellation handle for long-running work (CLI process and/or Dart loops).
class ActionCancelToken {
  bool _cancelled = false;
  Process? _process;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void attachProcess(Process process) {
    _process = process;
    if (_cancelled) {
      _killProcess(process);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final process = _process;
    if (process != null) {
      _killProcess(process);
    }
    for (final listener in List<void Function()>.from(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  void _killProcess(Process process) {
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {
      try {
        process.kill();
      } catch (_) {}
    }
  }
}

enum ActiveActionKind {
  joinChannels,
  inviteChildren,
  forwardLinks,
  forwardAndJoin,
  childrenJoin,
  motherDeploy,
  massInvite,
  leaveGroups,
  discoverChannels,
  postJoinMessage,
  broadcast,
  funnel,
  other;

  String get label => switch (this) {
        joinChannels => 'Вступление в каналы',
        inviteChildren => 'Приглашение',
        forwardLinks => 'Пересылка ссылок',
        forwardAndJoin => 'Переслать и вступить',
        childrenJoin => 'Вступление дочерних',
        motherDeploy => 'Полный цикл матки',
        massInvite => 'Массовый набор',
        leaveGroups => 'Выход из каналов',
        discoverChannels => 'Поиск каналов',
        postJoinMessage => 'Письма после вступления',
        broadcast => 'Рассылка',
        funnel => 'Воронка',
        other => 'Действие',
      };
}

enum ActiveActionStatus {
  running,
  cancelling,
  completed,
  failed,
  cancelled;

  bool get isActive => this == running || this == cancelling;

  String get label => switch (this) {
        running => 'Выполняется',
        cancelling => 'Остановка…',
        completed => 'Готово',
        failed => 'Ошибка',
        cancelled => 'Остановлено',
      };
}

class ActiveAction {
  ActiveAction({
    required this.id,
    required this.kind,
    required this.title,
    this.subtitle,
    DateTime? startedAt,
    ActionCancelToken? cancelToken,
  })  : startedAt = startedAt ?? DateTime.now(),
        cancelToken = cancelToken ?? ActionCancelToken();

  final String id;
  final ActiveActionKind kind;
  final String title;
  final String? subtitle;
  final DateTime startedAt;
  final ActionCancelToken cancelToken;

  ActiveActionStatus status = ActiveActionStatus.running;
  String progressMessage = '';
  int? done;
  int? total;
  DateTime? finishedAt;

  bool get isActive => status.isActive;

  Duration get elapsed {
    final end = finishedAt ?? DateTime.now();
    return end.difference(startedAt);
  }

  String get progressLabel {
    if (done != null && total != null && total! > 0) {
      return '$done / $total';
    }
    return progressMessage;
  }
}

/// Interruptible delay that ends early when [token] is cancelled.
Future<void> delayUnlessCancelled(
  Duration duration, {
  ActionCancelToken? token,
}) async {
  if (token == null || token.isCancelled) {
    if (token?.isCancelled != true) {
      await Future<void>.delayed(duration);
    }
    return;
  }
  final completer = Completer<void>();
  Timer? timer;
  void onCancel() {
    if (!completer.isCompleted) completer.complete();
  }

  token.addListener(onCancel);
  timer = Timer(duration, () {
    if (!completer.isCompleted) completer.complete();
  });
  try {
    await completer.future;
  } finally {
    timer.cancel();
    token.removeListener(onCancel);
  }
}
