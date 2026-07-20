import '../models/macro_scenario.dart';
import '../models/macro_step.dart';
import '../models/max_account.dart';
import 'emulator_service.dart';

typedef MacroLogCallback = void Function(String message);

class EmulatorMacroRunner {
  EmulatorMacroRunner._();

  static final EmulatorMacroRunner instance = EmulatorMacroRunner._();

  final EmulatorService _emulator = EmulatorService.instance;

  Future<void> runScenario(
    MaxAccount account,
    MacroScenario scenario, {
    MacroLogCallback? onLog,
  }) async {
    void log(String message) => onLog?.call(message);

    if (!account.emulator.isConfigured) {
      onLog?.call('AVD не сохранён в профиле — используем стандартное имя');
    }

    final sdk = await _emulator.detectSdk();
    if (!sdk.available || sdk.adbPath == null) {
      throw StateError('Android SDK не найден');
    }

    final adb = sdk.adbPath!;
    log('Поиск запущенного эмулятора…');
    final serial = await _emulator.resolveSerial(
      account,
      onProgress: log,
    );
    log('Эмулятор: $serial');

    for (var i = 0; i < scenario.steps.length; i++) {
      final step = scenario.steps[i];
      log('Шаг ${i + 1}/${scenario.steps.length}: ${step.displayLabel}');

      switch (step.type) {
        case MacroStepType.emulatorTap:
          final x = step.x ?? 0;
          final y = step.y ?? 0;
          await _emulator.inputTap(adb, serial, x, y);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        case MacroStepType.emulatorInputText:
          final text = step.text ?? '';
          if (text.isEmpty) {
            log('  пропуск: пустой текст');
          } else {
            await _emulator.inputText(adb, serial, text);
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
        case MacroStepType.emulatorPressEnter:
          await _emulator.inputKeyEvent(adb, serial, 66);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        case MacroStepType.emulatorSwipe:
          await _emulator.inputSwipe(
            adb,
            serial,
            step.x ?? 0,
            step.y ?? 0,
            step.x2 ?? 0,
            step.y2 ?? 0,
            durationMs: step.waitMs,
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
        case MacroStepType.emulatorLongPress:
          await _emulator.inputLongPress(
            adb,
            serial,
            step.x ?? 0,
            step.y ?? 0,
            durationMs: step.waitMs,
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
        case MacroStepType.wait:
          final ms = step.waitMs;
          log('  пауза ${ms}мс');
          await Future<void>.delayed(Duration(milliseconds: ms));
        default:
          log('  пропуск: шаг «${step.type.label}» только для Web');
      }
    }

    log('Сценарий «${scenario.name}» завершён');
  }
}
