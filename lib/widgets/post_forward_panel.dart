import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account_group_membership.dart';
import '../models/active_action.dart';
import '../models/chat_history_message.dart';
import '../providers/app_state.dart';
import '../services/max_mother_service.dart';

/// Browse posts from a group and forward selected ones into other chats.
class PostForwardPanel extends StatefulWidget {
  const PostForwardPanel({super.key});

  @override
  State<PostForwardPanel> createState() => _PostForwardPanelState();
}

class _PostForwardPanelState extends State<PostForwardPanel> {
  String? _accountId;
  String? _sourceChatId;
  final _selectedPosts = <String>{};
  final _selectedTargets = <String>{};
  final _posts = <ChatHistoryMessage>[];
  String _query = '';
  bool _loadingPosts = false;
  bool _forwarding = false;
  String? _error;

  void _ensureAccount(AppState state) {
    final accounts = state.accounts.where((a) => a.hasApiSession).toList();
    if (accounts.isEmpty) {
      _accountId = null;
      return;
    }
    if (_accountId == null || !accounts.any((a) => a.id == _accountId)) {
      _accountId = accounts.first.id;
    }
  }

  List<AccountGroupMembership> _memberships(AppState state) {
    final id = _accountId;
    if (id == null) return const [];
    final list = [...state.membershipsFor(id)];
    list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return list;
  }

  List<ChatHistoryMessage> get _filteredPosts {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _posts;
    return _posts
        .where(
          (p) =>
              p.preview.toLowerCase().contains(q) ||
              p.text.toLowerCase().contains(q) ||
              p.id.contains(q),
        )
        .toList();
  }

  Future<void> _loadPosts(AppState state) async {
    final accountId = _accountId;
    final chatId = _sourceChatId;
    if (accountId == null || chatId == null) return;
    final account = state.accountById(accountId);
    if (account == null || !account.hasApiSession) return;

    setState(() {
      _loadingPosts = true;
      _error = null;
      _selectedPosts.clear();
    });
    try {
      final result = await MaxMotherService.listChatMessages(
        token: account.apiToken!,
        chatId: chatId,
        limit: 80,
        proxy: account.isolation.proxyServer,
        onProgress: (msg) => state.browser.logMessage(msg),
      );
      if (!mounted) return;
      if (!result.ok) {
        setState(() {
          _posts.clear();
          _error = result.message;
        });
        return;
      }
      setState(() {
        _posts
          ..clear()
          ..addAll(result.messages);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _posts.clear();
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loadingPosts = false);
    }
  }

  Future<void> _forward(AppState state) async {
    final accountId = _accountId;
    final sourceChatId = _sourceChatId;
    if (accountId == null ||
        sourceChatId == null ||
        _selectedPosts.isEmpty ||
        _selectedTargets.isEmpty ||
        _forwarding) {
      return;
    }
    final account = state.accountById(accountId);
    if (account == null || !account.hasApiSession) return;

    final selected = _posts.where((p) => _selectedPosts.contains(p.id)).toList();
    if (selected.isEmpty) return;

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переслать посты?'),
        content: Text(
          'Постов: ${selected.length}\n'
          'Чатов: ${_selectedTargets.length}\n\n'
          'Будет попытка настоящей пересылки; если API не примет — '
          'отправится текстовая копия (без фото).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Переслать')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _forwarding = true);
    final action = state.beginAction(
      kind: ActiveActionKind.postJoinMessage,
      title: 'Пересылка постов',
      subtitle: '${selected.length} → ${_selectedTargets.length}',
    );
    try {
      final result = await MaxMotherService.forwardChatMessages(
        token: account.apiToken!,
        sourceChatId: sourceChatId,
        targetChatIds: _selectedTargets.toList(),
        messageIds: selected.map((e) => e.id).toList(),
        rawMessages: [
          for (final p in selected)
            if (p.raw != null) p.raw!,
        ],
        delayMs: 800,
        proxy: account.isolation.proxyServer,
        cancel: action.cancelToken,
        onProgress: (msg) {
          state.browser.logMessage(msg);
          state.updateActionProgress(action.id, message: msg);
        },
      );
      final summary = result.ok
          ? 'Переслано: ${result.forwarded} · копий: ${result.copied} · ошибок: ${result.failed}'
          : result.message;
      state.finishAction(
        action.id,
        status: result.ok ? ActiveActionStatus.completed : ActiveActionStatus.failed,
        message: summary,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary)));
      setState(() {
        _selectedPosts.clear();
        _selectedTargets.clear();
      });
    } catch (e) {
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _forwarding = false);
    }
  }

  String _fmtTime(ChatHistoryMessage m) {
    final t = m.sentAt;
    if (t == null) return '';
    final dd = t.day.toString().padLeft(2, '0');
    final mm = t.month.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final mi = t.minute.toString().padLeft(2, '0');
    return '$dd.$mm $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureAccount(state);
    final scheme = Theme.of(context).colorScheme;
    final accounts = state.accounts.where((a) => a.hasApiSession).toList();
    final memberships = _memberships(state);
    final posts = _filteredPosts;
    final targets = memberships.where((m) => m.chatId != _sourceChatId).toList();

    if (_sourceChatId != null && !memberships.any((m) => m.chatId == _sourceChatId)) {
      _sourceChatId = memberships.isNotEmpty ? memberships.first.chatId : null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Выберите аккаунт и группу — загрузите посты, отметьте нужные, '
                'затем выберите чаты и перешлите.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, height: 1.35),
              ),
              const SizedBox(height: 8),
              if (accounts.isEmpty)
                Text(
                  'Нет аккаунтов с токеном — войдите на вкладке «Вход».',
                  style: TextStyle(color: scheme.error, fontSize: 12),
                )
              else ...[
                DropdownButtonFormField<String>(
                  value: _accountId,
                  decoration: const InputDecoration(
                    labelText: 'Аккаунт',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text(
                          '${a.profileDisplayName} · ${state.membershipsFor(a.id).length} групп',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _loadingPosts || _forwarding
                      ? null
                      : (v) => setState(() {
                            _accountId = v;
                            _sourceChatId = null;
                            _posts.clear();
                            _selectedPosts.clear();
                            _selectedTargets.clear();
                          }),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _sourceChatId,
                        decoration: const InputDecoration(
                          labelText: 'Группа / канал (источник)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final m in memberships)
                            DropdownMenuItem(
                              value: m.chatId,
                              child: Text(
                                m.title.trim().isNotEmpty ? m.title : m.chatId,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _loadingPosts || _forwarding || memberships.isEmpty
                            ? null
                            : (v) => setState(() {
                                  _sourceChatId = v;
                                  _posts.clear();
                                  _selectedPosts.clear();
                                }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: _sourceChatId == null || _loadingPosts || _forwarding
                          ? null
                          : () => _loadPosts(state),
                      icon: _loadingPosts
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(_loadingPosts ? '…' : 'Загрузить'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_error!, style: TextStyle(color: scheme.error, fontSize: 12)),
          ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: _Pane(
                  title: 'Посты (${posts.length})',
                  trailing: Text(
                    'выбрано ${_selectedPosts.length}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                        child: TextField(
                          enabled: !_loadingPosts && !_forwarding,
                          decoration: const InputDecoration(
                            hintText: 'Поиск по тексту…',
                            isDense: true,
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.search, size: 18),
                          ),
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                      Expanded(
                        child: posts.isEmpty
                            ? Center(
                                child: Text(
                                  _loadingPosts
                                      ? 'Загрузка…'
                                      : 'Нет постов — выберите группу и нажмите «Загрузить»',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                itemCount: posts.length,
                                itemBuilder: (context, index) {
                                  final p = posts[index];
                                  final selected = _selectedPosts.contains(p.id);
                                  return CheckboxListTile(
                                    dense: true,
                                    value: selected,
                                    onChanged: _forwarding
                                        ? null
                                        : (v) => setState(() {
                                              if (v == true) {
                                                _selectedPosts.add(p.id);
                                              } else {
                                                _selectedPosts.remove(p.id);
                                              }
                                            }),
                                    secondary: Icon(
                                      p.hasPhoto
                                          ? Icons.photo_outlined
                                          : p.isForward
                                              ? Icons.reply_all_outlined
                                              : Icons.chat_bubble_outline,
                                      size: 18,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    title: Text(
                                      p.preview,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12, height: 1.3),
                                    ),
                                    subtitle: Text(
                                      [
                                        if (_fmtTime(p).isNotEmpty) _fmtTime(p),
                                        if (p.hasPhoto) 'фото',
                                        if (p.isForward) 'репост',
                                      ].join(' · '),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                    controlAffinity: ListTileControlAffinity.trailing,
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 4,
                child: _Pane(
                  title: 'Куда переслать (${targets.length})',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: targets.isEmpty || _forwarding
                            ? null
                            : () => setState(() {
                                  _selectedTargets
                                    ..clear()
                                    ..addAll(targets.map((t) => t.chatId));
                                }),
                        child: const Text('Все', style: TextStyle(fontSize: 11)),
                      ),
                      TextButton(
                        onPressed: _selectedTargets.isEmpty || _forwarding
                            ? null
                            : () => setState(() => _selectedTargets.clear()),
                        child: const Text('Сброс', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ),
                  child: targets.isEmpty
                      ? Center(
                          child: Text(
                            'Нет других групп у аккаунта',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          itemCount: targets.length,
                          itemBuilder: (context, index) {
                            final t = targets[index];
                            final selected = _selectedTargets.contains(t.chatId);
                            return CheckboxListTile(
                              dense: true,
                              value: selected,
                              onChanged: _forwarding
                                  ? null
                                  : (v) => setState(() {
                                        if (v == true) {
                                          _selectedTargets.add(t.chatId);
                                        } else {
                                          _selectedTargets.remove(t.chatId);
                                        }
                                      }),
                              title: Text(
                                t.title.trim().isNotEmpty ? t.title : t.chatId,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              controlAffinity: ListTileControlAffinity.trailing,
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: FilledButton.icon(
              onPressed: _forwarding ||
                      _selectedPosts.isEmpty ||
                      _selectedTargets.isEmpty
                  ? null
                  : () => _forward(state),
              icon: _forwarding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.forward_to_inbox_outlined, size: 18),
              label: Text(
                _forwarding
                    ? 'Пересылка…'
                    : 'Переслать ${_selectedPosts.length} → ${_selectedTargets.length} чат(ов)',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Pane extends StatelessWidget {
  const _Pane({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}
