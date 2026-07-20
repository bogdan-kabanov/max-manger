import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/macro_scenario.dart';
import '../models/macro_step.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';

class ScenarioPanel extends StatefulWidget {
  const ScenarioPanel({super.key});

  @override
  State<ScenarioPanel> createState() => _ScenarioPanelState();
}

class _ScenarioPanelState extends State<ScenarioPanel> {
  final _nameController = TextEditingController();
  final _intervalController = TextEditingController(text: '60');
  final _textController = TextEditingController();
  final _selectorController = TextEditingController();
  final _clickTextController = TextEditingController();
  final _xController = TextEditingController();
  final _yController = TextEditingController();
  final _waitController = TextEditingController(text: '1000');

  bool _scheduleEnabled = false;
  String? _loadedDraftId;

  @override
  void dispose() {
    _nameController.dispose();
    _intervalController.dispose();
    _textController.dispose();
    _selectorController.dispose();
    _clickTextController.dispose();
    _xController.dispose();
    _yController.dispose();
    _waitController.dispose();
    super.dispose();
  }

  void _loadDraft(MacroScenario? draft) {
    if (draft == null) return;
    _nameController.text = draft.name;
    _intervalController.text = draft.intervalMinutes.toString();
    _scheduleEnabled = draft.enabled;
  }

  Future<void> _saveScenario(AppState state) async {
    await state.saveEditingScenario(
      name: _nameController.text,
      intervalMinutes: int.tryParse(_intervalController.text) ?? 60,
      enabled: _scheduleEnabled,
    );
  }

  Future<void> _pickClick(AppState state) async {
    final step = await state.pickClickStep();
    if (step != null) {
      state.addStepToEditing(step);
    }
  }

  Future<void> _pickEmulatorTap(AppState state) async {
    state.enableEmulatorRecordMode();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ПКМ на экране эмулятора — добавить тап, свайп или долгое нажатие'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _addEmulatorChatTemplate(AppState state) {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала введите текст сообщения')),
      );
      return;
    }
    final base = DateTime.now().microsecondsSinceEpoch;
    final x = int.tryParse(_xController.text);
    final y = int.tryParse(_yController.text);
    if (x != null && y != null) {
      state.addStepToEditing(
        MacroStep(
          id: '${base}a',
          type: MacroStepType.emulatorTap,
          x: x,
          y: y,
          label: 'Тап поля ввода ($x, $y)',
        ),
      );
    }
    state.addStepToEditing(
      MacroStep(
        id: '${base}b',
        type: MacroStepType.emulatorInputText,
        text: _textController.text.trim(),
        label: 'Текст: ${_textController.text.trim()}',
      ),
    );
    state.addStepToEditing(MacroStep(id: '${base}c', type: MacroStepType.wait, waitMs: 500));
    state.addStepToEditing(
      MacroStep(id: '${base}d', type: MacroStepType.emulatorPressEnter, label: 'Enter'),
    );
  }

  void _addChatTemplate(AppState state) {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала введите текст сообщения выше')),
      );
      return;
    }
    final base = DateTime.now().microsecondsSinceEpoch;
    state.addStepToEditing(MacroStep(id: '${base}a', type: MacroStepType.focusInput));
    state.addStepToEditing(
      MacroStep(
        id: '${base}b',
        type: MacroStepType.typeText,
        text: _textController.text.trim(),
        selector: _selectorController.text.trim().isEmpty ? null : _selectorController.text.trim(),
        label: 'Текст: ${_textController.text.trim()}',
      ),
    );
    state.addStepToEditing(MacroStep(id: '${base}c', type: MacroStepType.wait, waitMs: 500));
    state.addStepToEditing(
      MacroStep(id: '${base}d', type: MacroStepType.clickSend, label: 'Отправить'),
    );
  }

  void _addManualStep(AppState state, MacroStepType type) {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    late final MacroStep step;

    switch (type) {
      case MacroStepType.typeText:
        if (_textController.text.trim().isEmpty) return;
        step = MacroStep(
          id: id,
          type: type,
          text: _textController.text.trim(),
          selector: _selectorController.text.trim().isEmpty ? null : _selectorController.text.trim(),
          label: 'Текст: ${_textController.text.trim()}',
        );
        _textController.clear();
      case MacroStepType.clickText:
        if (_clickTextController.text.trim().isEmpty) return;
        step = MacroStep(
          id: id,
          type: type,
          text: _clickTextController.text.trim(),
          label: 'Клик «${_clickTextController.text.trim()}»',
        );
        _clickTextController.clear();
      case MacroStepType.clickSelector:
        if (_selectorController.text.trim().isEmpty) return;
        step = MacroStep(
          id: id,
          type: type,
          selector: _selectorController.text.trim(),
          label: 'Клик: ${_selectorController.text.trim()}',
        );
      case MacroStepType.clickCoordinates:
        step = MacroStep(
          id: id,
          type: type,
          x: int.tryParse(_xController.text) ?? 0,
          y: int.tryParse(_yController.text) ?? 0,
          label: 'Клик (${_xController.text}, ${_yController.text})',
        );
      case MacroStepType.wait:
        step = MacroStep(
          id: id,
          type: type,
          waitMs: int.tryParse(_waitController.text) ?? 1000,
        );
      case MacroStepType.pressEnter:
      case MacroStepType.clickSend:
      case MacroStepType.focusInput:
        step = MacroStep(id: id, type: type);
      case MacroStepType.emulatorTap:
        step = MacroStep(
          id: id,
          type: type,
          x: int.tryParse(_xController.text) ?? 0,
          y: int.tryParse(_yController.text) ?? 0,
          label: 'Тап (${_xController.text}, ${_yController.text})',
        );
      case MacroStepType.emulatorInputText:
        if (_textController.text.trim().isEmpty) return;
        step = MacroStep(
          id: id,
          type: type,
          text: _textController.text.trim(),
          label: 'Текст: ${_textController.text.trim()}',
        );
        _textController.clear();
      case MacroStepType.emulatorPressEnter:
        step = MacroStep(id: id, type: type, label: 'Enter');
      case MacroStepType.emulatorSwipe:
        step = MacroStep(
          id: id,
          type: type,
          x: int.tryParse(_xController.text) ?? 0,
          y: int.tryParse(_yController.text) ?? 0,
          waitMs: int.tryParse(_waitController.text) ?? 300,
          label: 'Свайп — задайте конец через ПКМ на экране',
        );
      case MacroStepType.emulatorLongPress:
        step = MacroStep(
          id: id,
          type: type,
          x: int.tryParse(_xController.text) ?? 0,
          y: int.tryParse(_yController.text) ?? 0,
          waitMs: int.tryParse(_waitController.text) ?? 800,
          label: 'Долгое (${_xController.text}, ${_yController.text})',
        );
    }

    state.addStepToEditing(step);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final browser = context.watch<BrowserSessionManager>();
    final draft = state.editingScenario;
    final scenarios = state.scenariosForSelected();

    if (draft?.id != _loadedDraftId) {
      _loadedDraftId = draft?.id;
      if (draft != null) {
        _loadDraft(draft);
      } else {
        _nameController.clear();
        _intervalController.text = '60';
        _scheduleEnabled = false;
      }
    }

    if (draft != null) {
      return _buildEditor(context, state, browser, draft);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('Сценарии', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'Новый сценарий (Web)',
                onPressed: state.selectedAccount == null
                    ? null
                    : () => state.startNewScenario(target: MacroTarget.web),
                icon: const Icon(Icons.add_circle_outline),
              ),
              PopupMenuButton<MacroTarget>(
                tooltip: 'Новый сценарий',
                enabled: state.selectedAccount != null,
                onSelected: (target) => state.startNewScenario(target: target),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: MacroTarget.web, child: Text('Web (браузер)')),
                  PopupMenuItem(value: MacroTarget.emulator, child: Text('Эмулятор Android')),
                ],
                icon: const Icon(Icons.arrow_drop_down),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Автокликер: задайте шаги (клик, текст, отправка) и интервал повтора.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: scenarios.isEmpty
              ? const Center(child: Text('Сценариев пока нет'))
              : ListView.builder(
                  itemCount: scenarios.length,
                  itemBuilder: (context, index) {
                    final scenario = scenarios[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        title: Text(scenario.name),
                        subtitle: Text(
                          '${scenario.isEmulator ? 'Эмулятор' : 'Web'} · '
                          '${scenario.steps.length} шагов · каждые ${scenario.intervalMinutes} мин'
                          '${scenario.lastRunAt != null ? '\nПоследний запуск: ${_fmt(scenario.lastRunAt!)}' : ''}',
                        ),
                        isThreeLine: scenario.lastRunAt != null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: scenario.enabled,
                              onChanged: (v) => state.toggleScenario(scenario, v),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (action) async {
                                switch (action) {
                                  case 'run':
                                    await state.runScenarioNow(scenario);
                                  case 'edit':
                                    state.editScenario(scenario);
                                    _nameController.text = scenario.name;
                                    _intervalController.text = scenario.intervalMinutes.toString();
                                    _scheduleEnabled = scenario.enabled;
                                  case 'delete':
                                    await state.deleteScenario(scenario);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(value: 'run', child: Text('Запустить сейчас')),
                                PopupMenuItem(value: 'edit', child: Text('Редактировать')),
                                PopupMenuItem(value: 'delete', child: Text('Удалить')),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEditor(
    BuildContext context,
    AppState state,
    BrowserSessionManager browser,
    MacroScenario draft,
  ) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: state.cancelScenarioEdit,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const Expanded(
                    child: Text('Редактор сценария', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Название'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _intervalController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Интервал (минуты)',
                  hintText: '60',
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<MacroTarget>(
                segments: const [
                  ButtonSegment(
                    value: MacroTarget.web,
                    label: Text('Web'),
                    icon: Icon(Icons.web, size: 18),
                  ),
                  ButtonSegment(
                    value: MacroTarget.emulator,
                    label: Text('Эмулятор'),
                    icon: Icon(Icons.phone_android, size: 18),
                  ),
                ],
                selected: {draft.target},
                onSelectionChanged: (value) {
                  if (value.isNotEmpty) state.setEditingScenarioTarget(value.first);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Автозапуск по расписанию'),
                value: _scheduleEnabled,
                onChanged: (v) => setState(() => _scheduleEnabled = v),
              ),
              const Divider(),
              const Text('Добавить шаг', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (draft.isEmulator) ...[
                Text(
                  'Эмулятор внизу: ЛКМ — управление, ПКМ — добавить шаг в сценарий.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _pickEmulatorTap(state),
                      icon: const Icon(Icons.touch_app, size: 18),
                      label: const Text('Захватить тап'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _addEmulatorChatTemplate(state),
                      icon: const Icon(Icons.chat_outlined, size: 18),
                      label: const Text('Шаблон: сообщение'),
                    ),
                    OutlinedButton(
                      onPressed: () => _addManualStep(state, MacroStepType.emulatorPressEnter),
                      child: const Text('Enter'),
                    ),
                    OutlinedButton(
                      onPressed: () => _addManualStep(state, MacroStepType.wait),
                      child: const Text('Пауза'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _textController,
                  decoration: const InputDecoration(labelText: 'Текст для ввода в MAX'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _xController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'X (поле ввода, необяз.)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _yController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Y (поле ввода, необяз.)',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => _addManualStep(state, MacroStepType.emulatorInputText),
                  child: const Text('Добавить шаг «Ввести текст»'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _waitController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Пауза (мс)'),
                ),
              ] else ...[
              if (browser.isPicking)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Кликните элемент на странице MAX...')),
                      TextButton(onPressed: browser.cancelPick, child: const Text('Отмена')),
                    ],
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: browser.isPicking ? null : () => _pickClick(state),
                    icon: const Icon(Icons.ads_click, size: 18),
                    label: const Text('Захватить клик'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _addChatTemplate(state),
                    icon: const Icon(Icons.chat_outlined, size: 18),
                    label: const Text('Шаблон: написать в чат'),
                  ),
                  OutlinedButton(
                    onPressed: () => _addManualStep(state, MacroStepType.focusInput),
                    child: const Text('Фокус на ввод'),
                  ),
                  OutlinedButton(
                    onPressed: () => _addManualStep(state, MacroStepType.clickSend),
                    child: const Text('Отправить'),
                  ),
                  OutlinedButton(
                    onPressed: () => _addManualStep(state, MacroStepType.pressEnter),
                    child: const Text('Enter'),
                  ),
                  OutlinedButton(
                    onPressed: () => _addManualStep(state, MacroStepType.wait),
                    child: const Text('Пауза'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textController,
                decoration: const InputDecoration(labelText: 'Текст для ввода'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _selectorController,
                decoration: const InputDecoration(
                  labelText: 'CSS-селектор (необязательно для текста)',
                  hintText: 'div.chat-input',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => _addManualStep(state, MacroStepType.typeText),
                child: const Text('Добавить шаг «Ввести текст»'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _clickTextController,
                decoration: const InputDecoration(
                  labelText: 'Клик по тексту на странице',
                  hintText: 'Название чата',
                ),
              ),
              FilledButton(
                onPressed: () => _addManualStep(state, MacroStepType.clickText),
                child: const Text('Добавить шаг «Клик по тексту»'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _xController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'X'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _yController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Y'),
                    ),
                  ),
                ],
              ),
              OutlinedButton(
                onPressed: () => _addManualStep(state, MacroStepType.clickCoordinates),
                child: const Text('Добавить клик по координатам'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _waitController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Пауза (мс)'),
              ),
              ],
              const Divider(height: 24),
              Text('Шаги (${draft.steps.length})', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              if (draft.steps.isEmpty)
                const Text('Добавьте шаги с помощью кнопок выше')
              else
                ...draft.steps.asMap().entries.map((entry) {
                  final index = entry.key;
                  final step = entry.value;
                  return Card(
                    child: ListTile(
                      title: Text('${index + 1}. ${step.displayLabel}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_upward, size: 18),
                            onPressed: index > 0 ? () => state.moveStepUp(index) : null,
                          ),
                          IconButton(
                            icon: const Icon(Icons.arrow_downward, size: 18),
                            onPressed: index < draft.steps.length - 1
                                ? () => state.moveStepDown(index)
                                : null,
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () => state.removeStepFromEditing(step.id),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: state.cancelScenarioEdit,
                  child: const Text('Отмена'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: draft.steps.isEmpty
                      ? null
                      : () async {
                          await _saveScenario(state);
                          _nameController.clear();
                          _intervalController.text = '60';
                        },
                  child: const Text('Сохранить'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
