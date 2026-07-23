import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/map_workflow.dart';
import '../../providers/app_state.dart';

Future<void> showBroadcastConfigSheet(
  BuildContext context, {
  required MapWorkflowNode node,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _BroadcastConfigSheet(node: node),
  );
}

Future<void> showGroupConfigSheet(
  BuildContext context, {
  required MapWorkflowNode node,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => _GroupConfigSheet(node: node),
  );
}

class _GroupConfigSheet extends StatefulWidget {
  const _GroupConfigSheet({required this.node});

  final MapWorkflowNode node;

  @override
  State<_GroupConfigSheet> createState() => _GroupConfigSheetState();
}

class _GroupConfigSheetState extends State<_GroupConfigSheet> {
  late final TextEditingController _title;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.node.title);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Группа', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: 'Название',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              TextButton.icon(
                onPressed: () async {
                  await state.deleteWorkflowNode(widget.node.id);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                label: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () async {
                  await state.updateWorkflowNode(widget.node.copyWith(title: _title.text.trim()));
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BroadcastConfigSheet extends StatefulWidget {
  const _BroadcastConfigSheet({required this.node});

  final MapWorkflowNode node;

  @override
  State<_BroadcastConfigSheet> createState() => _BroadcastConfigSheetState();
}

class _BroadcastConfigSheetState extends State<_BroadcastConfigSheet> {
  late TextEditingController _title;
  late TextEditingController _chats;
  late TextEditingController _interval;
  late List<_StepRow> _steps;
  String? _senderId;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    final cfg = widget.node.broadcast ?? const BroadcastWorkflowConfig();
    _title = TextEditingController(text: widget.node.title);
    _chats = TextEditingController(text: cfg.targetChats.join('\n'));
    _interval = TextEditingController(text: cfg.intervalMinutes.toString());
    _senderId = cfg.senderAccountId;
    _enabled = cfg.enabled;
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
    _chats.dispose();
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

  BroadcastWorkflowConfig _buildConfig() {
    return BroadcastWorkflowConfig(
      senderAccountId: _senderId,
      targetChats: _chats.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
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
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final accounts = state.accounts;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Material(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('Рассылка', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Настройте тексты, паузы между ними и чаты-получатели',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Название карточки',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                value: _senderId != null && accounts.any((a) => a.id == _senderId) ? _senderId : null,
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
              const SizedBox(height: 12),
              TextField(
                controller: _chats,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Чаты (по одному в строке)',
                  hintText: 'Елена\nVIP ногти',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Сообщения', style: Theme.of(context).textTheme.titleSmall),
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
                            labelText: 'Пауза после (сек.) до следующего',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
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
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await state.deleteWorkflowNode(widget.node.id);
                      if (context.mounted) Navigator.pop(context);
                    },
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
                    onPressed: () async {
                      await _save(state);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('Сохранить'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
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

String? senderLabelFor(AppState state, String workflowId) {
  final senderId = state.senderAccountIdForWorkflow(workflowId);
  if (senderId == null) return null;
  for (final a in state.accounts) {
    if (a.id == senderId) return a.label;
  }
  return null;
}
