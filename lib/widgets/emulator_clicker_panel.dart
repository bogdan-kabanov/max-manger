import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/macro_scenario.dart';
import '../models/macro_step.dart';
import '../providers/app_state.dart';

class EmulatorClickerPanel extends StatefulWidget {
  const EmulatorClickerPanel({super.key});

  @override
  State<EmulatorClickerPanel> createState() => _EmulatorClickerPanelState();
}

class _EmulatorClickerPanelState extends State<EmulatorClickerPanel> {
  final _nameController = TextEditingController();
  final _textController = TextEditingController();
  final _waitController = TextEditingController(text: '500');
  String? _loadedDraftId;

  @override
  void dispose() {
    _nameController.dispose();
    _textController.dispose();
    _waitController.dispose();
    super.dispose();
  }

  void _syncDraft(MacroScenario? draft) {
    if (draft?.id == _loadedDraftId) return;
    _loadedDraftId = draft?.id;
    if (draft != null) {
      _nameController.text = draft.name;
    } else {
      _nameController.clear();
    }
  }

  void _addTextStep(AppState state) {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    state.addStepToEditing(
      MacroStep(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: MacroStepType.emulatorInputText,
        text: text,
        label: 'Текст: $text',
      ),
    );
    _textController.clear();
  }

  void _addMessageTemplate(AppState state) {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите текст сообщения')),
      );
      return;
    }
    final base = DateTime.now().microsecondsSinceEpoch;
    state.addStepToEditing(
      MacroStep(
        id: '${base}b',
        type: MacroStepType.emulatorInputText,
        text: text,
        label: 'Текст: $text',
      ),
    );
    state.addStepToEditing(MacroStep(id: '${base}c', type: MacroStepType.wait, waitMs: 500));
    state.addStepToEditing(
      MacroStep(id: '${base}d', type: MacroStepType.emulatorPressEnter, label: 'Enter'),
    );
    _textController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final draft = state.editingScenario;
    final scenarios = state.scenariosForSelected().where((s) => s.isEmulator).toList();
    _syncDraft(draft);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Кликер сценариев', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'ПКМ на экране — тап/свайп/долгое в сценарий. ЛКМ — управление MAX.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: state.selectedAccount == null
                      ? null
                      : () => state.startNewScenario(target: MacroTarget.emulator),
                  child: const Text('Новый'),
                ),
                if (scenarios.isNotEmpty)
                  PopupMenuButton<MacroScenario>(
                    tooltip: 'Открыть сценарий',
                    onSelected: state.editScenario,
                    itemBuilder: (context) => scenarios
                        .map((s) => PopupMenuItem(value: s, child: Text(s.name)))
                        .toList(),
                    child: const Chip(label: Text('Открыть…')),
                  ),
                if (draft != null)
                  TextButton(onPressed: state.cancelScenarioEdit, child: const Text('Закрыть')),
              ],
            ),
          ),
          if (draft != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Название сценария', isDense: true),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _textController,
                decoration: const InputDecoration(
                  labelText: 'Текст для MAX',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  OutlinedButton(
                    onPressed: () => _addTextStep(state),
                    child: const Text('+ Текст'),
                  ),
                  OutlinedButton(
                    onPressed: () => _addMessageTemplate(state),
                    child: const Text('Шаблон сообщения'),
                  ),
                  OutlinedButton(
                    onPressed: () => state.addStepToEditing(
                      MacroStep(
                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                        type: MacroStepType.emulatorPressEnter,
                      ),
                    ),
                    child: const Text('Enter'),
                  ),
                  OutlinedButton(
                    onPressed: () => state.addStepToEditing(
                      MacroStep(
                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                        type: MacroStepType.wait,
                        waitMs: int.tryParse(_waitController.text) ?? 500,
                      ),
                    ),
                    child: const Text('Пауза'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: draft.steps.isEmpty
                  ? const Center(
                      child: Text(
                        'Нет шагов\nПКМ на экране — добавить действие',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: draft.steps.length,
                      itemBuilder: (context, index) {
                        final step = draft.steps[index];
                        return Card(
                          child: ListTile(
                            dense: true,
                            title: Text('${index + 1}. ${step.displayLabel}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => state.removeStepFromEditing(step.id),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: draft.steps.isEmpty
                          ? null
                          : () async {
                              await state.runScenarioNow(
                                draft.copyWith(
                                  name: _nameController.text.trim().isEmpty
                                      ? draft.name
                                      : _nameController.text.trim(),
                                ),
                              );
                            },
                      child: const Text('Запустить'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: draft.steps.isEmpty
                          ? null
                          : () => state.saveEditingScenario(
                                name: _nameController.text,
                                intervalMinutes: 60,
                                enabled: false,
                              ),
                      child: const Text('Сохранить'),
                    ),
                  ),
                ],
              ),
            ),
          ] else
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Создайте сценарий. ЛКМ — управлять MAX. ПКМ — записывать шаги.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
