import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/join_message_template.dart';
import '../models/max_account.dart';
import '../models/template_sent_record.dart';
import '../providers/app_state.dart';
import '../models/template_send_scope.dart';

enum _SentFilter { all, pending, sent }

/// Раздача-like management for template broadcast: timing, status, send, delete.
class TemplateChannelsPanel extends StatefulWidget {
  const TemplateChannelsPanel({
    super.key,
    required this.template,
    this.onEditMessages,
  });

  final JoinMessageTemplate template;
  final VoidCallback? onEditMessages;

  @override
  State<TemplateChannelsPanel> createState() => _TemplateChannelsPanelState();
}

class _TemplateChannelsPanelState extends State<TemplateChannelsPanel> {
  String? _accountId;
  _SentFilter _filter = _SentFilter.all;
  final _selected = <String>{};
  String _query = '';
  bool _busy = false;

  JoinMessageTemplate get template => widget.template;

  void _ensureAccount(AppState state) {
    final writers = state
        .joinTemplateWriterAccountIds(template.id)
        .map(state.accountById)
        .whereType<MaxAccount>()
        .where((a) => a.hasApiSession && state.canSendJoinMessages(a.id))
        .toList();
    if (writers.isEmpty) {
      _accountId = null;
      return;
    }
    if (_accountId == null || !writers.any((a) => a.id == _accountId)) {
      _accountId = writers.first.id;
    }
  }

  List<({String chatId, String title, TemplateSentRecord? record})> _allRows(
    AppState state,
  ) {
    final accountId = _accountId;
    if (accountId == null) return const [];

    final memberships = state.membershipsFor(accountId);
    final byChat = <String, String>{
      for (final m in memberships)
        m.chatId: m.title.trim().isNotEmpty ? m.title : m.chatId,
    };
    for (final r in state.storage.templateSentRecordsFor(
      templateId: template.id,
      accountId: accountId,
    )) {
      byChat.putIfAbsent(
        r.chatId,
        () => r.title.trim().isNotEmpty ? r.title : r.chatId,
      );
    }

    final rows = [
      for (final e in byChat.entries)
        (
          chatId: e.key,
          title: e.value,
          record: state.storage.templateSentRecord(
            accountId: accountId,
            chatId: e.key,
            templateId: template.id,
          ),
        ),
    ];
    rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return rows;
  }

  List<({String chatId, String title, TemplateSentRecord? record})> _rows(
    AppState state,
  ) {
    var rows = _allRows(state);

    rows = switch (_filter) {
      _SentFilter.all => rows,
      _SentFilter.pending => rows.where((r) => r.record == null).toList(),
      _SentFilter.sent => rows.where((r) => r.record != null).toList(),
    };

    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      rows = rows
          .where(
            (r) =>
                r.title.toLowerCase().contains(q) ||
                r.chatId.contains(q),
          )
          .toList();
    }
    return rows;
  }

  String _fmtDuration(int ms) {
    if (ms >= 3600000 && ms % 3600000 == 0) return '${ms ~/ 3600000} ч';
    if (ms >= 60000 && ms % 60000 == 0) return '${ms ~/ 60000} мин';
    if (ms >= 1000 && ms % 1000 == 0) return '${ms ~/ 1000} сек';
    return '${(ms / 1000).toStringAsFixed(1)} сек';
  }

  Future<void> _pickGap(AppState state) async {
    final presets = <(String, int)>[
      ('30 сек', 30000),
      ('1 мин', 60000),
      ('2 мин', 120000),
      ('5 мин', 300000),
      ('10 мин', 600000),
      ('1 час', 3600000),
    ];
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Пауза между чатами'),
        children: [
          for (final p in presets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p.$2),
              child: Text(
                '${p.$1}  ·  1-й сразу, 2-й через ${p.$1}, 3-й через 2×…',
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await state.updateJoinMessageTemplate(template.copyWith(chatGapMs: picked));
  }

  Future<void> _pickRepeat(AppState state) async {
    final presets = <(String, int)>[
      ('Выкл.', 0),
      ('Каждые 30 мин', 1800000),
      ('Каждый 1 час', 3600000),
      ('Каждые 2 часа', 7200000),
      ('Каждые 6 часов', 21600000),
      ('Раз в сутки', 86400000),
    ];
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Повтор рассылки'),
        children: [
          for (final p in presets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p.$2),
              child: Text(p.$1, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await state.updateJoinMessageTemplate(
      template.copyWith(
        repeatEnabled: picked > 0,
        repeatIntervalMs: picked > 0 ? picked : template.repeatIntervalMs,
      ),
    );
  }

  Future<void> _send(AppState state, {required bool onlySelected}) async {
    final accountId = _accountId;
    if (accountId == null || _busy) return;
    final chatIds = onlySelected && _selected.isNotEmpty
        ? _selected.toList()
        : [
            for (final r in _allRows(state))
              if (r.record == null) r.chatId,
          ];
    if (chatIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет чатов для отправки')),
      );
      return;
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отправить шаблон?'),
        content: Text(
          'Чатов: ${chatIds.length}\n'
          'Пауза между чатами: ${_fmtDuration(template.chatGapMs)}\n'
          '(1-й сразу, 2-й через ${_fmtDuration(template.chatGapMs)}, …)\n'
          'Повтор: ${template.repeatEnabled ? _fmtDuration(template.repeatIntervalMs) : 'выкл'}\n\n'
          '${onlySelected && _selected.isNotEmpty ? 'Только выбранные чаты.' : 'Только куда ещё не писал.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отправить')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final sent = await state.broadcastTemplateToExistingGroups(
        templateId: template.id,
        onlyAccountIds: {accountId},
        scope: TemplateSendScope.all,
        onlyChatIds: chatIds.toSet(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(sent > 0 ? 'Отправлено сообщений: $sent' : 'Ничего не отправлено')),
      );
      setState(() => _selected.clear());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(AppState state) async {
    final accountId = _accountId;
    if (accountId == null || _selected.isEmpty || _busy) return;
    final account = state.accountById(accountId);
    if (account == null || !account.hasApiSession) return;

    final items = <Map<String, dynamic>>[];
    for (final chatId in _selected) {
      final rec = state.storage.templateSentRecord(
        accountId: accountId,
        chatId: chatId,
        templateId: template.id,
      );
      if (rec == null || rec.messageIds.isEmpty) continue;
      items.add({'chatId': chatId, 'messageIds': rec.messageIds});
    }
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Нет сохранённых id сообщений для удаления. '
            'Удалять можно только после отправки из этой версии.',
          ),
        ),
      );
      return;
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сообщения?'),
        content: Text(
          'Чатов с известными id: ${items.length} из ${_selected.length}.\n'
          'Удаление для всех участников чата (если API позволит).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await state.deleteTemplateMessages(
        account: account,
        templateId: template.id,
        chatIds: _selected.toList(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result)),
      );
      setState(() => _selected.clear());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureAccount(state);
    final scheme = Theme.of(context).colorScheme;
    final writers = state
        .joinTemplateWriterAccountIds(template.id)
        .map(state.accountById)
        .whereType<MaxAccount>()
        .where((a) => a.hasApiSession && state.canSendJoinMessages(a.id))
        .toList();
    final allRows = _allRows(state);
    final rows = _rows(state);
    final pending = allRows.where((r) => r.record == null).length;
    final sent = allRows.where((r) => r.record != null).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (writers.isEmpty)
                Text(
                  'Нет дочек с токеном для этого шаблона — привяжите на вкладке «Матки» / «Аккаунты».',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                )
              else
                DropdownButtonFormField<String>(
                  value: _accountId,
                  decoration: const InputDecoration(
                    labelText: 'Кто пишет',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final a in writers)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text(
                          '${a.profileDisplayName} · каналов ${state.membershipsFor(a.id).length}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                            _accountId = v;
                            _selected.clear();
                          }),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilterChip(
                    label: Text(
                      'Все (${allRows.length})',
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: _filter == _SentFilter.all,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _filter = _SentFilter.all),
                  ),
                  FilterChip(
                    label: Text('Не писал ($pending)', style: const TextStyle(fontSize: 11)),
                    selected: _filter == _SentFilter.pending,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _filter = _SentFilter.pending),
                  ),
                  FilterChip(
                    label: Text('Уже писал ($sent)', style: const TextStyle(fontSize: 11)),
                    selected: _filter == _SentFilter.sent,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _filter = _SentFilter.sent),
                  ),
                  ActionChip(
                    label: Text(
                      'Между чатами: ${_fmtDuration(template.chatGapMs)}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onPressed: _busy ? null : () => _pickGap(state),
                  ),
                  ActionChip(
                    label: Text(
                      template.repeatEnabled
                          ? 'Повтор: ${_fmtDuration(template.repeatIntervalMs)}'
                          : 'Повтор: выкл',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onPressed: _busy ? null : () => _pickRepeat(state),
                  ),
                  if (widget.onEditMessages != null)
                    ActionChip(
                      label: const Text('Текст', style: TextStyle(fontSize: 11)),
                      onPressed: _busy ? null : widget.onEditMessages,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                enabled: !_busy,
                decoration: const InputDecoration(
                  hintText: 'Поиск…',
                  isDense: true,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: rows.isEmpty || _busy
                        ? null
                        : () => setState(() {
                              _selected
                                ..clear()
                                ..addAll(rows.map((r) => r.chatId));
                            }),
                    child: const Text('Выбрать все', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: _selected.isEmpty || _busy
                        ? null
                        : () => setState(() => _selected.clear()),
                    child: const Text('Сбросить', style: TextStyle(fontSize: 12)),
                  ),
                  const Spacer(),
                  Text(
                    'выбрано ${_selected.length}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    _accountId == null
                        ? 'Нет аккаунта для рассылки'
                        : 'Нет каналов — сначала вступления на Раздаче / у дочки',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final r = rows[index];
                    final selected = _selected.contains(r.chatId);
                    final wrote = r.record != null;
                    final when = r.record?.sentAt;
                    return CheckboxListTile(
                      dense: true,
                      value: selected,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                                if (v == true) {
                                  _selected.add(r.chatId);
                                } else {
                                  _selected.remove(r.chatId);
                                }
                              }),
                      secondary: Icon(
                        wrote ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 18,
                        color: wrote ? Colors.greenAccent : scheme.onSurfaceVariant,
                      ),
                      title: Text(
                        r.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        wrote
                            ? 'уже писал'
                                '${when != null ? ' · ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}' : ''}'
                                '${(r.record?.messageIds.isNotEmpty ?? false) ? ' · можно удалить' : ''}'
                            : 'ещё не писал · слот ~${_fmtDuration(index * template.chatGapMs)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: wrote
                              ? Colors.greenAccent.withValues(alpha: 0.85)
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      controlAffinity: ListTileControlAffinity.trailing,
                    );
                  },
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _busy || _accountId == null
                      ? null
                      : () => _send(state, onlySelected: _selected.isNotEmpty),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.campaign_outlined, size: 18),
                  label: Text(
                    _busy
                        ? 'Отправка…'
                        : _selected.isNotEmpty
                            ? 'Отправить в выбранные (${_selected.length})'
                            : 'Отправить куда ещё не писал ($pending)',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy || _selected.isEmpty ? null : () => _delete(state),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(
                    _selected.isEmpty
                        ? 'Удалить сообщения (выберите чаты)'
                        : 'Удалить в выбранных (${_selected.length})',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
