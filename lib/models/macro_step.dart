enum MacroStepType {
  clickSelector,
  clickText,
  clickCoordinates,
  typeText,
  pressEnter,
  clickSend,
  wait,
  focusInput,
  emulatorTap,
  emulatorInputText,
  emulatorPressEnter,
  emulatorSwipe,
  emulatorLongPress,
}

extension MacroStepTypeLabel on MacroStepType {
  bool get isEmulator => name.startsWith('emulator');

  String get label => switch (this) {
        MacroStepType.clickSelector => 'Клик по элементу',
        MacroStepType.clickText => 'Клик по тексту',
        MacroStepType.clickCoordinates => 'Клик по координатам',
        MacroStepType.typeText => 'Ввести текст',
        MacroStepType.pressEnter => 'Нажать Enter',
        MacroStepType.clickSend => 'Отправить сообщение',
        MacroStepType.wait => 'Пауза',
        MacroStepType.focusInput => 'Фокус на поле ввода',
        MacroStepType.emulatorTap => 'Эмулятор: тап',
        MacroStepType.emulatorInputText => 'Эмулятор: ввод текста',
        MacroStepType.emulatorPressEnter => 'Эмулятор: Enter',
        MacroStepType.emulatorSwipe => 'Эмулятор: свайп',
        MacroStepType.emulatorLongPress => 'Эмулятор: долгое нажатие',
      };
}

class MacroStep {
  MacroStep({
    required this.id,
    required this.type,
    this.selector,
    this.text,
    this.x,
    this.y,
    this.x2,
    this.y2,
    this.waitMs = 1000,
    this.label,
  });

  final String id;
  final MacroStepType type;
  final String? selector;
  final String? text;
  final int? x;
  final int? y;
  final int? x2;
  final int? y2;
  final int waitMs;
  final String? label;

  String get displayLabel {
    if (label != null && label!.trim().isNotEmpty) return label!;
    return switch (type) {
      MacroStepType.clickSelector => 'Клик: ${selector ?? "?"}',
      MacroStepType.clickText => 'Клик «${text ?? ""}»',
      MacroStepType.clickCoordinates => 'Клик ($x, $y)',
      MacroStepType.typeText => 'Текст: ${text ?? ""}',
      MacroStepType.pressEnter => 'Enter',
      MacroStepType.clickSend => 'Отправить',
      MacroStepType.wait => 'Пауза $waitMs мс',
      MacroStepType.focusInput => 'Фокус на ввод',
      MacroStepType.emulatorTap => 'Тап ($x, $y)',
      MacroStepType.emulatorInputText => 'Ввод: ${text ?? ""}',
      MacroStepType.emulatorPressEnter => 'Enter (эмулятор)',
      MacroStepType.emulatorSwipe => 'Свайп ($x,$y)→($x2,$y2)',
      MacroStepType.emulatorLongPress => 'Долгое ($x, $y)',
    };
  }

  MacroStep copyWith({
    MacroStepType? type,
    String? selector,
    String? text,
    int? x,
    int? y,
    int? x2,
    int? y2,
    int? waitMs,
    String? label,
  }) {
    return MacroStep(
      id: id,
      type: type ?? this.type,
      selector: selector ?? this.selector,
      text: text ?? this.text,
      x: x ?? this.x,
      y: y ?? this.y,
      x2: x2 ?? this.x2,
      y2: y2 ?? this.y2,
      waitMs: waitMs ?? this.waitMs,
      label: label ?? this.label,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'selector': selector,
        'text': text,
        'x': x,
        'y': y,
        'x2': x2,
        'y2': y2,
        'waitMs': waitMs,
        'label': label,
      };

  factory MacroStep.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'wait';
    MacroStepType type;
    try {
      type = MacroStepType.values.byName(typeName);
    } catch (_) {
      type = MacroStepType.wait;
    }
    return MacroStep(
      id: json['id'] as String,
      type: type,
      selector: json['selector'] as String?,
      text: json['text'] as String?,
      x: json['x'] as int?,
      y: json['y'] as int?,
      x2: json['x2'] as int?,
      y2: json['y2'] as int?,
      waitMs: json['waitMs'] as int? ?? 1000,
      label: json['label'] as String?,
    );
  }

  Map<String, dynamic> toScriptJson() => {
        'type': type.name,
        'selector': selector,
        'text': text,
        'x': x,
        'y': y,
        'x2': x2,
        'y2': y2,
        'waitMs': waitMs,
      };
}
