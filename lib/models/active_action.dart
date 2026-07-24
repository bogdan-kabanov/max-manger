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
        motherDeploy => 'Полный цикл родителя',
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

class ActiveActionLogLine {
  ActiveActionLogLine({
    required this.message,
    this.level = 'info',
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final DateTime time;
  final String message;
  final String level;
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

  /// Chronological detailed log (newest at the end).
  final List<ActiveActionLogLine> logs = [];
  static const int maxLogs = 800;

  /// When set, UI shows a live countdown until this instant.
  DateTime? waitUntil;
  String? waitLabel;

  bool get isActive => status.isActive;

  Duration get elapsed {
    final end = finishedAt ?? DateTime.now();
    return end.difference(startedAt);
  }

  Duration? get waitRemaining {
    final until = waitUntil;
    if (until == null) return null;
    final rem = until.difference(DateTime.now());
    if (rem.isNegative) return Duration.zero;
    return rem;
  }

  bool get isWaiting {
    final rem = waitRemaining;
    return rem != null && rem > Duration.zero;
  }

  String get progressLabel {
    if (done != null && total != null && total! > 0) {
      return '$done / $total';
    }
    return progressMessage;
  }

  void appendLog(String message, {String level = 'info'}) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    if (logs.isNotEmpty && logs.last.message == trimmed) return;
    logs.add(ActiveActionLogLine(message: trimmed, level: level));
    if (logs.length > maxLogs) {
      logs.removeRange(0, logs.length - maxLogs);
    }
  }

  void beginWait(Duration duration, {String? label}) {
    if (duration <= Duration.zero) {
      clearWait();
      return;
    }
    waitUntil = DateTime.now().add(duration);
    waitLabel = label;
  }

  void clearWait() {
    waitUntil = null;
    waitLabel = null;
  }
}

/// Interruptible delay that ends early when [token] is cancelled.
///
/// Optional [onTick] is called about once per second with time remaining
/// (useful for live countdowns in the UI).
Future<void> delayUnlessCancelled(
  Duration duration, {
  ActionCancelToken? token,
  void Function(Duration remaining)? onTick,
}) async {
  if (token == null || token.isCancelled) {
    if (token?.isCancelled != true) {
      if (onTick == null) {
        await Future<void>.delayed(duration);
      } else {
        await _delayWithTicks(duration, onTick: onTick);
      }
    }
    return;
  }
  final completer = Completer<void>();
  Timer? timer;
  Timer? tickTimer;
  final deadline = DateTime.now().add(duration);

  void onCancel() {
    if (!completer.isCompleted) completer.complete();
  }

  void emitTick() {
    final rem = deadline.difference(DateTime.now());
    onTick!(rem.isNegative ? Duration.zero : rem);
  }

  token.addListener(onCancel);
  timer = Timer(duration, () {
    if (!completer.isCompleted) completer.complete();
  });
  if (onTick != null) {
    emitTick();
    tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (completer.isCompleted) return;
      emitTick();
    });
  }
  try {
    await completer.future;
  } finally {
    timer.cancel();
    tickTimer?.cancel();
    token.removeListener(onCancel);
  }
}

Future<void> _delayWithTicks(
  Duration duration, {
  required void Function(Duration remaining) onTick,
}) async {
  final deadline = DateTime.now().add(duration);
  while (true) {
    final rem = deadline.difference(DateTime.now());
    if (rem <= Duration.zero) {
      onTick(Duration.zero);
      return;
    }
    onTick(rem);
    final slice = rem < const Duration(seconds: 1) ? rem : const Duration(seconds: 1);
    await Future<void>.delayed(slice);
  }
}
