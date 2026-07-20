import 'dart:async';

import '../models/macro_scenario.dart';

typedef ScenarioRunner = Future<void> Function(MacroScenario scenario);

class ScenarioScheduler {
  final Map<String, Timer> _timers = {};

  void sync({
    required String activeAccountId,
    required List<MacroScenario> scenarios,
    required ScenarioRunner runner,
  }) {
    final desiredKeys = <String>{};

    for (final scenario in scenarios) {
      if (!scenario.enabled || scenario.accountId != activeAccountId) continue;
      if (scenario.steps.isEmpty) continue;
      if (scenario.intervalMinutes < 1) continue;

      final key = scenario.id;
      desiredKeys.add(key);

      if (_timers.containsKey(key)) continue;

      final interval = Duration(minutes: scenario.intervalMinutes);
      _timers[key] = Timer.periodic(interval, (_) {
        unawaited(runner(scenario));
      });
    }

    for (final key in _timers.keys.toList()) {
      if (!desiredKeys.contains(key)) {
        _timers.remove(key)?.cancel();
      }
    }
  }

  void stopAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  void dispose() => stopAll();
}
