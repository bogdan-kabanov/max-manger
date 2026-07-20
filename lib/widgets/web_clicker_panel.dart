import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/macro_scenario.dart';
import '../models/macro_step.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';

class WebClickerPanel extends StatefulWidget {
  const WebClickerPanel({super.key});

  @override
  State<WebClickerPanel> createState() => _WebClickerPanelState();
}

class _WebClickerPanelState extends State<WebClickerPanel> {
  final _textController = TextEditingController();
  final _nameController = TextEditingController();
  String? _loadedDraftId;

  @override
  void dispose() {
    _textController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickClick(AppState state) async {
    final step = await state.pickClickStep();
    if (step != null) state.addStepToEditing(step);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final browser = context.watch<BrowserSessionManager>();
    final draft = state.editingScenario;
    final webScenarios = state.scenariosForSelected().where((s) => !s.isEmulator).toList();

    if (draft?.id != _loadedDraftId) {
      _loadedDraftId = draft?.id;
      _nameController.text = draft?.name ?? '';
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Web-кликер', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => state.startNewScenario(target: MacroTarget.web),
                  child: const Text('Новый'),
                ),
                if (webScenarios.isNotEmpty)
                  PopupMenuButton<MacroScenario>(
                    onSelected: state.editScenario,
                    itemBuilder: (context) => webScenarios
                        .map((s) => PopupMenuItem(value: s, child: Text(s.name)))
                        .toList(),
                    child: const Chip(label: Text('Открыть…')),
                  ),
              ],
            ),
          ),
          if (browser.isPicking)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Кликните элемент на странице MAX…',
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          if (draft != null && !draft.isEmulator) ...[
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Название', isDense: true),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  OutlinedButton.icon(
                    onPressed: browser.isPicking ? null : () => _pickClick(state),
                    icon: const Icon(Icons.ads_click, size: 16),
                    label: const Text('Захватить клик'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      final text = _textController.text.trim();
                      if (text.isEmpty) return;
                      state.addStepToEditing(
                        MacroStep(
                          id: DateTime.now().microsecondsSinceEpoch.toString(),
                          type: MacroStepType.typeText,
                          text: text,
                          label: 'Текст: $text',
                        ),
                      );
                      _textController.clear();
                    },
                    child: const Text('+ Текст'),
                  ),
                  OutlinedButton(
                    onPressed: () => state.addStepToEditing(
                      MacroStep(
                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                        type: MacroStepType.clickSend,
                      ),
                    ),
                    child: const Text('Отправить'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _textController,
                decoration: const InputDecoration(
                  labelText: 'Текст сообщения',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: draft.steps.length,
                itemBuilder: (context, index) {
                  final step = draft.steps[index];
                  return ListTile(
                    dense: true,
                    title: Text('${index + 1}. ${step.displayLabel}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => state.removeStepFromEditing(step.id),
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
                          : () => state.runScenarioNow(draft.copyWith(
                                name: _nameController.text.trim().isEmpty
                                    ? draft.name
                                    : _nameController.text.trim(),
                              )),
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
            const Expanded(
              child: Center(child: Text('Создайте web-сценарий\nи захватывайте клики на странице')),
            ),
        ],
      ),
    );
  }
}
