import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/map_workflow.dart';
import '../../models/max_account.dart';
import '../../providers/app_state.dart';
import 'map_chat_checkbox_list.dart';

class BroadcastMapPanel extends StatefulWidget {
  const BroadcastMapPanel({super.key, required this.node});

  final MapWorkflowNode node;

  @override
  State<BroadcastMapPanel> createState() => _BroadcastMapPanelState();
}

class _BroadcastMapPanelState extends State<BroadcastMapPanel> {
  late TextEditingController _title;
  late TextEditingController _interval;
  late List<_StepRow> _steps;
  String? _senderId;
  bool _enabled = false;
  late Set<String> _selectedChats;

  @override
  void initState() {
    super.initState();
    _loadFromNode(widget.node);
  }

  @override
  void didUpdateWidget(covariant BroadcastMapPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.id != widget.node.id) {
      for (final row in _steps) {
        row.dispose();
      }
      _loadFromNode(widget.node);
    }
  }

  void _loadFromNode(MapWorkflowNode node) {
    final cfg = node.broadcast ?? const BroadcastWorkflowConfig();
    _title = TextEditingController(text: node.title);
    _interval = TextEditingController(text: cfg.intervalMinutes.toString());
    _senderId = cfg.senderAccountId;
    _enabled = cfg.enabled;
    _selectedChats = {...cfg.targetChats};
    _steps = cfg.steps
        .map((s) => _StepRow(
              id: s.id,
              text: TextEditingController(text: s.text),
              delaySec: TextEditingController(text: (s.delayAfterMs / 1000).round().toString()),
            ))
        .toList();
    if (_steps.isEmpty) _addStep();
  }

  @override
  void dispose() {
    _title.dispose();
    _interval.dispose();
    for (final row in _steps) {
      row.dispose();
    }
    super.dispose();
  }

  void _addStep() {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _steps.add(_StepRow(
        id: id,
        text: TextEditingController(),
        delaySec: TextEditingController(text: '5'),
      ));
    });
  }

  List<String> _groupChats(AppState state) {
    final parentId = widget.node.parentGroupId;
    if (parentId == null) return const [];
    final group = state.workflowNodes.byId(parentId);
    return group?.group?.targetChats ?? const [];
  }

  BroadcastWorkflowConfig _buildConfig() {
    return BroadcastWorkflowConfig(
      senderAccountId: _senderId,
      targetChats: _selectedChats.toList(),
      steps: _steps
          .map((row) => BroadcastMessageStep(
                id: row.id,
                text: row.text.text,
                delayAfterMs: (int.tryParse(row.delaySec.text) ?? 5) * 1000,
              ))
          .where((s) => s.text.trim().isNotEmpty)
          .toList(),
      intervalMinutes: int.tryParse(_interval.text) ?? 0,
      enabled: _enabled,
    );
  }

  Future<void> _save(AppState state) async {
    final updated = widget.node.copyWith(
      title: _title.text.trim().isEmpty ? widget.node.title : _title.text.trim(),
      broadcast: _buildConfig(),
    );
    await state.updateWorkflowNode(updated);
    if (_senderId != null) {
      await state.addWorkflowSenderEdge(accountId: _senderId!, workflowId: widget.node.id);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Рассылка сохранена')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final accounts = state.accounts;
    final groupChats = _groupChats(state);
    final parentGroup = widget.node.parentGroupId != null
        ? state.workflowNodes.byId(widget.node.parentGroupId!)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            children: [
              Row(
                children: [
                  Icon(Icons.campaign_outlined, color: theme.colorScheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Рассылка',
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              if (parentGroup != null) ...[
                const SizedBox(height: 4),
                Text('Группа: ${parentGroup.title}', style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Название на карте',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _senderId != null && accounts.any((a) => a.id == _senderId) ? _senderId : null,
                decoration: const InputDecoration(
                  labelText: 'Аккаунт-отправитель',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('— не выбран —')),
                  ...accounts.map(
                    (a) => DropdownMenuItem(
                      value: a.id,
                      child: Text('${a.label}${a.hasApiSession ? '' : ' (нет токена)'}'),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _senderId = v),
              ),
              const SizedBox(height: 16),
              Text('Куда слать', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              if (groupChats.isEmpty)
                Text(
                  parentGroup == null
                      ? 'Привяжите рассылку к группе и выберите чаты в настройках группы.'
                      : 'В группе «${parentGroup.title}» не выбраны чаты. Отметьте их в настройках группы.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                )
              else
                MapChatCheckboxList(
                  availableChats: groupChats,
                  selectedChats: _selectedChats,
                  onChanged: (next) => setState(() => _selectedChats = next),
                  emptyHint: 'Нет доступных чатов',
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Сообщения', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addStep,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Добавить'),
                  ),
                ],
              ),
              ..._steps.asMap().entries.map((entry) {
                final i = entry.key;
                final row = entry.value;
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Text('Сообщение ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            const Spacer(),
                            IconButton(
                              tooltip: 'Удалить',
                              visualDensity: VisualDensity.compact,
                              onPressed: _steps.length <= 1
                                  ? null
                                  : () => setState(() {
                                        row.dispose();
                                        _steps.removeAt(i);
                                      }),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                        TextField(
                          controller: row.text,
                          minLines: 2,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            hintText:
                                'Текст… Ссылка: [Вступить](https://max.ru/join/…)',
                            helperText: 'Скрытая ссылка: [текст](https://…)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: row.delaySec,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Пауза после (сек.)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              TextField(
                controller: _interval,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Повторять каждые N минут (0 = только вручную)',
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Автозапуск по таймеру'),
                subtitle: const Text('Работает если интервал ≥ 1 мин'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => state.deleteWorkflowNode(widget.node.id),
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    label: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _save(state);
                      await state.runBroadcastWorkflow(widget.node.id);
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Запустить'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _save(state),
                    child: const Text('Сохранить'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepRow {
  _StepRow({
    required this.id,
    required this.text,
    required this.delaySec,
  });

  final String id;
  final TextEditingController text;
  final TextEditingController delaySec;

  void dispose() {
    text.dispose();
    delaySec.dispose();
  }
}
