import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/account_map_state.dart';
import '../models/active_action.dart';
import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import '../models/pipeline_journal_event.dart';
import '../providers/app_state.dart';
import '../services/max_mother_service.dart';
import '../services/storage_service.dart';
import '../utils/join_link_parser.dart';

enum _GroupsFilter { all, free, mother }

/// Groups catalog under Accounts: parse, paste links, assign to parents — as a table.
class GroupsPanel extends StatefulWidget {
  const GroupsPanel({super.key});

  @override
  State<GroupsPanel> createState() => _GroupsPanelState();
}

class _GroupsPanelState extends State<GroupsPanel> {
  final _selectedChatIds = ValueNotifier<Set<String>>(<String>{});
  /// While dragging LMB across checkboxes: true = select, false = deselect.
  bool? _dragSelectTo;
  String _search = '';
  _GroupsFilter _filter = _GroupsFilter.all;
  String? _filterMotherId;
  String? _assignMotherId;
  bool _busy = false;
  bool _parsing = false;
  bool _joining = false;
  /// Parent joins and invites children by ID (for non-RU kids). Else join by invite links.
  bool _inviteById = true;

  Set<String> get _selected => _selectedChatIds.value;

  @override
  void dispose() {
    _selectedChatIds.dispose();
    super.dispose();
  }

  void _clearSelection() {
    if (_selectedChatIds.value.isEmpty) return;
    _selectedChatIds.value = <String>{};
  }

  void _mutateSelection(void Function(Set<String> next) fn) {
    final next = Set<String>.from(_selectedChatIds.value);
    fn(next);
    _selectedChatIds.value = next;
  }

  void _beginDragSelect(String chatId) {
    _dragSelectTo = !_selectedChatIds.value.contains(chatId);
    _applyDragSelect(chatId);
  }

  void _applyDragSelect(String chatId) {
    final want = _dragSelectTo;
    if (want == null) return;
    final has = _selectedChatIds.value.contains(chatId);
    if (has == want) return;
    _mutateSelection((s) {
      if (want) {
        s.add(chatId);
      } else {
        s.remove(chatId);
      }
    });
  }

  void _endDragSelect() => _dragSelectTo = null;

  List<MaxAccount> _mothers(AppState state) {
    final out = <MaxAccount>[];
    for (final c in state.motherClusters) {
      final id = c.motherAccountId;
      if (id == null) continue;
      final a = state.accountById(id);
      if (a != null) out.add(a);
    }
    out.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return out;
  }

  MotherCluster? _clusterForMother(AppState state, String motherId) {
    for (final c in state.motherClusters) {
      if (c.motherAccountId == motherId) return c;
    }
    return null;
  }

  void _ensureMothers(AppState state) {
    final mothers = _mothers(state);
    if (mothers.isEmpty) {
      _filterMotherId = null;
      _assignMotherId = null;
      if (_filter == _GroupsFilter.mother) _filter = _GroupsFilter.all;
      return;
    }
    if (_filterMotherId == null || !mothers.any((m) => m.id == _filterMotherId)) {
      _filterMotherId = mothers.first.id;
    }
    if (_assignMotherId == null || !mothers.any((m) => m.id == _assignMotherId)) {
      _assignMotherId = mothers.first.id;
    }
  }

  List<MaxChannelCatalogEntry> _filtered(AppState state) {
    var list = state.channelCatalog;
    switch (_filter) {
      case _GroupsFilter.free:
        list = list.where((e) => !e.isAssigned).toList();
      case _GroupsFilter.mother:
        final mid = _filterMotherId;
        list = mid == null
            ? const []
            : list.where((e) => e.assignedMotherAccountId == mid).toList();
      case _GroupsFilter.all:
        break;
    }

    final q = _search.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (e) =>
                e.title.toLowerCase().contains(q) ||
                e.chatId.toLowerCase().contains(q) ||
                (e.inviteHash?.toLowerCase().contains(q) ?? false) ||
                (e.inviteUrl?.toLowerCase().contains(q) ?? false) ||
                (e.source?.toLowerCase().contains(q) ?? false) ||
                (e.topic?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    return list;
  }

  String _motherLabel(AppState state, String? motherId) {
    if (motherId == null || motherId.isEmpty) return 'свободна';
    return state.accountById(motherId)?.label ?? motherId;
  }

  String _joinStatus(AppState state, MaxChannelCatalogEntry e) {
    final mid = e.assignedMotherAccountId;
    if (mid == null) return '—';
    final cluster = _clusterForMother(state, mid);
    if (cluster == null) return '—';
    final childIds = cluster.childAccountIds;
    final solo = childIds.isEmpty;
    final total = solo ? 1 : childIds.length;
    final joined = state.childrenJoinedChat(motherAccountId: mid, chatId: e.chatId);
    final label = solo ? 'акк' : 'дочки';
    return '$label ${joined.length}/$total';
  }

  String _sourceLabel(MaxChannelCatalogEntry e) {
    final s = e.source?.trim();
    if (s == null || s.isEmpty) return '—';
    return switch (s) {
      'paste' => 'ссылка',
      'discover' || 'catalog' => 'парсинг',
      _ => s,
    };
  }

  Future<void> _pasteLinks(AppState state) async {
    final mothers = _mothers(state);
    var motherId = _assignMotherId;
    final ctrl = TextEditingController();
    try {
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
      if (clip != null &&
          (clip.contains('max.ru/join/') || JoinLinkParser.parseHashes(clip).isNotEmpty)) {
        ctrl.text = clip;
      }
    } catch (_) {}

    if (!mounted) return;
    final result = await showDialog<({String text, String? motherId})>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Вставить ссылки'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Список https://max.ru/join/… или хешей — по одному в строке.',
                      style: TextStyle(fontSize: 12, height: 1.35, color: Colors.white70),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String?>(
                      value: motherId,
                      decoration: const InputDecoration(
                        labelText: 'Родитель (необязательно)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Без назначения'),
                        ),
                        for (final m in mothers)
                          DropdownMenuItem<String?>(
                            value: m.id,
                            child: Text(m.label),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => motherId = v),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: ctrl,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        hintText: 'https://max.ru/join/…\nhttps://max.ru/join/…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, (text: ctrl.text, motherId: motherId)),
                  child: const Text('Добавить'),
                ),
              ],
            );
          },
        );
      },
    );
    ctrl.dispose();
    if (result == null || !mounted) return;

    final parsed = JoinLinkParser.parseHashes(result.text);
    if (parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не нашли ссылки max.ru/join/…')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final imported = await state.importJoinLinks(
        rawText: result.text,
        motherAccountId: result.motherId,
      );
      if (!mounted) return;
      _clearSelection();
      setState(() {
        if (result.motherId != null) {
          _filter = _GroupsFilter.mother;
          _filterMotherId = result.motherId;
          _assignMotherId = result.motherId;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Добавлено: ${imported.added}'
            '${imported.alreadyKnown > 0 ? ' · уже были: ${imported.alreadyKnown}' : ''}'
            ' (из ${parsed.length})',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _assignSelected(AppState state, {required bool clear}) async {
    if (_selected.isEmpty) return;
    final motherId = clear ? null : _assignMotherId;
    if (!clear && motherId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала создайте родительский кластер во вкладке «Аккаунты»')),
      );
      return;
    }

    if (!clear) {
      final conflicts = state.channelCatalog
          .where(
            (e) =>
                _selected.contains(e.chatId) &&
                e.isAssigned &&
                e.assignedMotherAccountId != motherId,
          )
          .toList();
      if (conflicts.isNotEmpty && mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Переназначить группы?'),
            content: Text(
              '${conflicts.length} уже закреплены за другим родителем. Перенести?',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Перенести')),
            ],
          ),
        );
        if (ok != true) return;
      }
    }

    setState(() => _busy = true);
    try {
      await state.assignCatalogGroupsToMother(
        chatIds: _selected.toList(),
        motherAccountId: motherId,
      );
      if (!mounted) return;
      _clearSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            clear
                ? 'Назначение снято'
                : 'Назначено родителю «${_motherLabel(state, motherId)}»',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected(AppState state) async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить группы?'),
        content: Text('Убрать $n групп из каталога. Из MAX никто не выйдет.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await state.removeCatalogGroups(_selected);
      if (!mounted) return;
      _clearSelection();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll(AppState state) async {
    final n = state.channelCatalog.length;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить каталог?'),
        content: Text(
          'Удалить все $n групп.\n\n'
          'История уже найденных (${StorageService.instance.seenDiscoverCount}) сохранится — '
          'повторный парсинг не предложит те же группы.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Очистить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await state.clearChannelCatalog();
    if (!mounted) return;
    _clearSelection();
  }

  Future<void> _showParseDialog(AppState state) async {
    final accounts = state.accounts.where((a) => a.hasApiSession).toList();
    if (accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нужен аккаунт с API-токеном')),
      );
      return;
    }

    final cliReady = await MaxMotherService.isAvailable();
    if (!mounted) return;
    if (!cliReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('CLI недоступен — нужен Node.js и npm install в tools/max_auth'),
        ),
      );
      return;
    }

    final keywordCtrl = TextEditingController();
    final keywords = List<String>.from(StorageService.instance.discoverKeywords);
    var accountId = state.selectedAccount?.hasApiSession == true
        ? state.selectedAccount!.id
        : accounts.first.id;
    var count = 30;
    var discoverKind = 'chats';
    const countOptions = [5, 10, 20, 30, 50, 100];

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Спарсить группы'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      value: accountId,
                      decoration: const InputDecoration(
                        labelText: 'Аккаунт',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final a in accounts)
                          DropdownMenuItem(value: a.id, child: Text(a.label)),
                      ],
                      onChanged: (v) {
                        if (v != null) setLocal(() => accountId = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: discoverKind,
                      decoration: const InputDecoration(
                        labelText: 'Тип',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'chats', child: Text('Чаты (можно писать)')),
                        DropdownMenuItem(value: 'channels', child: Text('Каналы')),
                        DropdownMenuItem(value: 'all', child: Text('Чаты и каналы')),
                      ],
                      onChanged: (v) {
                        if (v != null) setLocal(() => discoverKind = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      value: countOptions.contains(count) ? count : 30,
                      decoration: const InputDecoration(
                        labelText: 'Сколько найти',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final n in countOptions)
                          DropdownMenuItem(value: n, child: Text('$n')),
                      ],
                      onChanged: (v) {
                        if (v != null) setLocal(() => count = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: keywordCtrl,
                      decoration: InputDecoration(
                        labelText: 'Ключевые слова',
                        hintText: 'чат, группа, крипто…',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: IconButton(
                          tooltip: 'Добавить',
                          onPressed: () {
                            final chunk = keywordCtrl.text
                                .split(RegExp(r'[,;\n|]+'))
                                .map((t) => t.trim())
                                .where((t) => t.isNotEmpty);
                            setLocal(() {
                              for (final w in chunk) {
                                if (!keywords.any((k) => k.toLowerCase() == w.toLowerCase())) {
                                  keywords.add(w);
                                }
                              }
                              keywordCtrl.clear();
                            });
                          },
                          icon: const Icon(Icons.add, size: 18),
                        ),
                      ),
                      onSubmitted: (_) {
                        final chunk = keywordCtrl.text
                            .split(RegExp(r'[,;\n|]+'))
                            .map((t) => t.trim())
                            .where((t) => t.isNotEmpty);
                        setLocal(() {
                          for (final w in chunk) {
                            if (!keywords.any((k) => k.toLowerCase() == w.toLowerCase())) {
                              keywords.add(w);
                            }
                          }
                          keywordCtrl.clear();
                        });
                      },
                    ),
                    if (keywords.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final w in keywords)
                            InputChip(
                              label: Text(w, style: const TextStyle(fontSize: 12)),
                              onDeleted: () => setLocal(() => keywords.remove(w)),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      keywords.isEmpty
                          ? 'Без слов — открытый поиск любых чатов.'
                          : 'Поиск по ${keywords.length} словам.',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Спарсить'),
                ),
              ],
            );
          },
        );
      },
    );

    final pendingKeywords = keywordCtrl.text
        .split(RegExp(r'[,;\n|]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty);
    for (final w in pendingKeywords) {
      if (!keywords.any((k) => k.toLowerCase() == w.toLowerCase())) {
        keywords.add(w);
      }
    }
    keywordCtrl.dispose();

    if (go != true || !mounted) return;
    await StorageService.instance.saveDiscoverKeywords(keywords);
    await _runDiscover(
      state: state,
      accountId: accountId,
      topics: keywords,
      count: count,
      discoverKind: discoverKind,
    );
  }

  Future<void> _runDiscover({
    required AppState state,
    required String accountId,
    required List<String> topics,
    required int count,
    required String discoverKind,
  }) async {
    final account = state.accountById(accountId);
    if (account == null || !account.hasApiSession || _parsing) return;

    setState(() => _parsing = true);
    final catalog = state.channelCatalog;
    final openSearch = topics.isEmpty;
    final batchSize = openSearch ? count.clamp(1, 200) : 10;
    final excludeHashes = openSearch
        ? catalog.where((e) => e.hasInviteLink).map((e) => e.inviteHash!).toList()
        : <String>{
            ...StorageService.instance.discoverExcludeHashes,
            ...catalog.where((e) => e.hasInviteLink).map((e) => e.inviteHash!),
          }.toList();
    final excludeChatIds = openSearch
        ? catalog.map((e) => e.chatId).toList()
        : <String>{
            ...StorageService.instance.discoverExcludeChatIds,
            ...catalog.map((e) => e.chatId),
          }.toList();

    final action = state.beginAction(
      kind: ActiveActionKind.discoverChannels,
      title: 'Парсинг групп',
      subtitle: 'до $count',
    );

    var totalAdded = 0;
    var emptyStreak = 0;
    var batchNo = 0;

    try {
      await state.ensureViewerId(account);
      final fresh = state.accountById(account.id)!;

      while (totalAdded < count && mounted && !action.cancelToken.isCancelled) {
        batchNo++;
        final need = count - totalAdded;
        final ask = need < batchSize ? need : batchSize;
        state.updateActionProgress(
          action.id,
          message: openSearch
              ? 'Открытый поиск · до $ask · есть $totalAdded'
              : 'Партия $batchNo · до $ask · есть $totalAdded',
          done: totalAdded,
          total: count,
        );

        final result = await MaxMotherService.discoverChannels(
          token: fresh.apiToken!,
          count: ask,
          topics: topics,
          kind: discoverKind,
          excludeHashes: excludeHashes,
          excludeChatIds: excludeChatIds,
          proxy: fresh.isolation.proxyServer,
          cancel: action.cancelToken,
          onProgress: (msg) {
            state.updateActionProgress(action.id, message: msg);
          },
        );

        if (!mounted || action.cancelToken.isCancelled) break;

        final got = result.channels.length;
        if (got > 0) {
          await state.mergeChannelCatalogEntries(result.channels);
          for (final e in result.channels) {
            if (e.hasInviteLink) excludeHashes.add(e.inviteHash!);
            excludeChatIds.add(e.chatId);
          }
          totalAdded += got;
          emptyStreak = 0;
        } else {
          emptyStreak++;
          final emptyLimit = totalAdded > 0 ? 2 : 3;
          if (emptyStreak >= emptyLimit) break;
        }

        if (totalAdded < count) {
          await delayUnlessCancelled(
            const Duration(milliseconds: 400),
            token: action.cancelToken,
          );
        }
      }

      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
        message: 'Добавлено $totalAdded',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action.cancelToken.isCancelled
                ? 'Парсинг остановлен · +$totalAdded'
                : totalAdded > 0
                    ? 'Добавлено групп: $totalAdded'
                    : 'Новых групп не найдено',
          ),
        ),
      );
    } catch (e) {
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка парсинга: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  Future<void> _copyLink(MaxChannelCatalogEntry e) async {
    final url = e.inviteUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ссылка скопирована'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _joinSelected(AppState state) async {
    if (_joining || _busy || _parsing || _selected.isEmpty) return;

    final byMother = <String, Set<String>>{};
    var unassigned = 0;
    for (final chatId in _selected) {
      MaxChannelCatalogEntry? entry;
      for (final e in state.channelCatalog) {
        if (e.chatId == chatId) {
          entry = e;
          break;
        }
      }
      final mid = entry?.assignedMotherAccountId;
      if (mid == null || mid.isEmpty) {
        unassigned++;
        continue;
      }
      byMother.putIfAbsent(mid, () => <String>{}).add(chatId);
    }

    if (byMother.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Сначала назначьте выбранные группы родителям'),
        ),
      );
      return;
    }

    final hasChildren = byMother.keys.any((mid) {
      final c = _clusterForMother(state, mid);
      return c != null && c.childAccountIds.isNotEmpty;
    });
    final useInviteById = hasChildren && _inviteById;

    final lines = <String>[];
    for (final entry in byMother.entries) {
      final mother = state.accountById(entry.key);
      final plan = state.buildPipelineLaunchPlan(
        alreadyJoinedChatIds: state.joinedChatIdsForPipeline(),
        onlyMotherId: entry.key,
        onlyChatIds: entry.value,
      );
      final cluster = _clusterForMother(state, entry.key);
      final solo = cluster == null || cluster.childAccountIds.isEmpty;
      lines.add(
        '«${mother?.label ?? entry.key}»: '
        '${plan.ok ? plan.summaryLine : (plan.error ?? 'пусто')}'
        '${solo ? ' · соло' : ''}',
      );
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(useInviteById ? 'Пригласить дочек?' : 'Вступить в группы?'),
        content: Text(
          '${lines.join('\n')}\n\n'
          '${unassigned > 0 ? 'Без родителя пропущено: $unassigned\n\n' : ''}'
          '${useInviteById ? 'Режим: родитель войдёт и пригласит дочек по ID.' : hasChildren ? 'Режим: вступление по ссылкам (дочки сами).' : 'Режим: аккаунт родителя вступает сам.'}\n'
          'Уже вступившие пропускаются. Шаблон/рассылка не запускается.',
          style: const TextStyle(height: 1.35),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(useInviteById ? 'Пригласить' : 'Вступить'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _joining = true);
    final action = state.beginAction(
      kind: useInviteById ? ActiveActionKind.inviteChildren : ActiveActionKind.childrenJoin,
      title: useInviteById ? 'Приглашение дочек' : 'Вступление в группы',
      subtitle: '${byMother.length} род. · ${_selected.length} групп',
    );
    final messages = <String>[];

    try {
      for (final entry in byMother.entries) {
        if (action.cancelToken.isCancelled) break;
        final mother = state.accountById(entry.key);
        final label = mother?.label ?? entry.key;
        state.updateActionProgress(action.id, message: '«$label»…');
        await state.addPipelineJournal(
          kind: PipelineJournalKind.launchPlan,
          message: 'Группы · ${useInviteById ? 'приглашение' : 'вступление'} «$label»',
          motherAccountId: entry.key,
          detail: entry.value.take(20).join(', '),
        );

        final cluster = _clusterForMother(state, entry.key);
        final solo = cluster == null || cluster.childAccountIds.isEmpty;
        final inviteThis = !solo && useInviteById;

        final resultMessage = inviteThis
            ? (await state.runPipelineChildrenJoinById(
                onlyMotherId: entry.key,
                onlyChatIds: entry.value,
                cancel: action.cancelToken,
                actionId: action.id,
              ))
                .message
            : (await state.runPipelineChildrenJoinByLinks(
                onlyMotherId: entry.key,
                onlyChatIds: entry.value,
                cancel: action.cancelToken,
                actionId: action.id,
              ))
                .message;
        messages.add('«$label»: $resultMessage');
      }

      final summary = messages.isEmpty ? 'Остановлено' : messages.join('\n');
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
        message: summary,
      );
      if (!mounted) return;
      _clearSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(summary), duration: const Duration(seconds: 5)),
      );
    } catch (e) {
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _assignOne(AppState state, MaxChannelCatalogEntry e) async {
    final mothers = _mothers(state);
    if (mothers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет родительских аккаунтов — создайте кластер')),
      );
      return;
    }
    String? motherId = e.assignedMotherAccountId ?? _assignMotherId ?? mothers.first.id;
    final picked = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: Text('Назначить «${e.title}»'),
              content: DropdownButtonFormField<String?>(
                value: motherId,
                decoration: const InputDecoration(
                  labelText: 'Родитель',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Свободна'),
                  ),
                  for (final m in mothers)
                    DropdownMenuItem<String?>(value: m.id, child: Text(m.label)),
                ],
                onChanged: (v) => setLocal(() => motherId = v),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, motherId ?? ''),
                  child: const Text('Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );
    if (picked == null || !mounted) return;
    await state.assignCatalogGroupsToMother(
      chatIds: [e.chatId],
      motherAccountId: picked.isEmpty ? null : picked,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureMothers(state);
    final mothers = _mothers(state);
    final rows = _filtered(state);
    final total = state.channelCatalog.length;
    final freeCount = state.channelCatalog.where((e) => !e.isAssigned).length;

    final catalogIds = {for (final e in state.channelCatalog) e.chatId};
    final sel = _selectedChatIds.value;
    if (sel.isNotEmpty && sel.any((id) => !catalogIds.contains(id))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _selectedChatIds.value = _selectedChatIds.value.intersection(catalogIds);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: InputDecoration(
                    hintText: 'Поиск по названию, ссылке…',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixText: '${rows.length}/$total',
                  ),
                ),
              ),
              SegmentedButton<_GroupsFilter>(
                segments: [
                  const ButtonSegment(value: _GroupsFilter.all, label: Text('Все')),
                  ButtonSegment(
                    value: _GroupsFilter.free,
                    label: Text('Свободные ($freeCount)'),
                  ),
                  const ButtonSegment(value: _GroupsFilter.mother, label: Text('Родитель')),
                ],
                selected: {_filter},
                onSelectionChanged: (v) => setState(() => _filter = v.first),
              ),
              if (_filter == _GroupsFilter.mother && mothers.isNotEmpty)
                SizedBox(
                  width: 200,
                  child: DropdownButtonFormField<String>(
                    value: _filterMotherId,
                    decoration: const InputDecoration(
                      labelText: 'Родитель',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final m in mothers)
                        DropdownMenuItem(value: m.id, child: Text(m.label)),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _filterMotherId = v);
                    },
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: ValueListenableBuilder<Set<String>>(
            valueListenable: _selectedChatIds,
            builder: (context, selected, _) {
              final n = selected.length;
              final empty = n == 0;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed:
                        (_busy || _parsing || _joining) ? null : () => _showParseDialog(state),
                    icon: _parsing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.travel_explore, size: 18),
                    label: Text(_parsing ? 'Парсинг…' : 'Спарсить'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed:
                        (_busy || _parsing || _joining) ? null : () => _pasteLinks(state),
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Вставить ссылки'),
                  ),
                  FilledButton.icon(
                    onPressed: (_busy || _parsing || _joining || empty)
                        ? null
                        : () => _joinSelected(state),
                    icon: _joining
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _inviteById ? Icons.person_add_alt_1 : Icons.login,
                            size: 18,
                          ),
                    label: Text(
                      _joining
                          ? 'Вступление…'
                          : (_inviteById
                              ? 'Вступить / пригласить ($n)'
                              : 'Вступить ($n)'),
                    ),
                  ),
                  FilterChip(
                    label: const Text('Пригласить по ID'),
                    selected: _inviteById,
                    onSelected: (_busy || _parsing || _joining)
                        ? null
                        : (v) => setState(() => _inviteById = v),
                    tooltip:
                        'Вкл: родитель войдёт и пригласит дочек. Выкл: вступление по ссылкам. Соло-родитель всегда входит сам.',
                  ),
                  if (mothers.isNotEmpty) ...[
                    SizedBox(
                      width: 200,
                      child: DropdownButtonFormField<String>(
                        value: _assignMotherId,
                        decoration: const InputDecoration(
                          labelText: 'Назначить родителю',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final m in mothers)
                            DropdownMenuItem(value: m.id, child: Text(m.label)),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _assignMotherId = v);
                        },
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: (_busy || _joining || empty)
                          ? null
                          : () => _assignSelected(state, clear: false),
                      child: Text('Назначить ($n)'),
                    ),
                    TextButton(
                      onPressed: (_busy || _joining || empty)
                          ? null
                          : () => _assignSelected(state, clear: true),
                      child: const Text('Снять'),
                    ),
                  ] else
                    const Text(
                      'Нет родителей — создайте кластер во вкладке «Аккаунты»',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  TextButton(
                    onPressed:
                        (_busy || _joining || empty) ? null : () => _deleteSelected(state),
                    child: const Text('Удалить'),
                  ),
                  TextButton(
                    onPressed: (_busy || _joining || total == 0) ? null : () => _clearAll(state),
                    child: const Text('Очистить всё'),
                  ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    total == 0
                        ? 'Каталог пуст — спарсьте группы или вставьте ссылки'
                        : 'Ничего не найдено',
                    style: const TextStyle(color: Colors.white54),
                  ),
                )
              : _buildCatalogTable(context, state, rows),
        ),
      ],
    );
  }

  Widget _buildCatalogTable(
    BuildContext context,
    AppState state,
    List<MaxChannelCatalogEntry> rows,
  ) {
    const rowH = 52.0;
    const colCheck = 48.0;
    const colGroup = 280.0;
    const colLink = 240.0;
    const colParent = 120.0;
    const colSource = 110.0;
    const colJoins = 110.0;
    const colActions = 132.0;
    const tableMin = colCheck + colGroup + colLink + colParent + colSource + colJoins + colActions;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tableWidth = constraints.maxWidth < tableMin ? tableMin : constraints.maxWidth;
        return Listener(
          onPointerUp: (_) => _endDragSelect(),
          onPointerCancel: (_) => _endDragSelect(),
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: tableWidth,
                child: Column(
                  children: [
                    _buildCatalogHeader(
                      rows: rows,
                      colCheck: colCheck,
                      colGroup: colGroup,
                      colLink: colLink,
                      colParent: colParent,
                      colSource: colSource,
                      colJoins: colJoins,
                      colActions: colActions,
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        itemExtent: rowH,
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final e = rows[index];
                          return _buildCatalogRow(
                            context,
                            state,
                            e,
                            rowH: rowH,
                            colCheck: colCheck,
                            colGroup: colGroup,
                            colLink: colLink,
                            colParent: colParent,
                            colSource: colSource,
                            colJoins: colJoins,
                            colActions: colActions,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCatalogHeader({
    required List<MaxChannelCatalogEntry> rows,
    required double colCheck,
    required double colGroup,
    required double colLink,
    required double colParent,
    required double colSource,
    required double colJoins,
    required double colActions,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: colCheck,
              child: ValueListenableBuilder<Set<String>>(
                valueListenable: _selectedChatIds,
                builder: (context, selected, _) {
                  final allVisible =
                      rows.isNotEmpty && rows.every((e) => selected.contains(e.chatId));
                  final noneVisible = rows.every((e) => !selected.contains(e.chatId));
                  return Checkbox(
                    value: allVisible ? true : (noneVisible ? false : null),
                    tristate: true,
                    onChanged: (v) {
                      _mutateSelection((s) {
                        if (v == true) {
                          s.addAll(rows.map((e) => e.chatId));
                        } else {
                          for (final e in rows) {
                            s.remove(e.chatId);
                          }
                        }
                      });
                    },
                  );
                },
              ),
            ),
            _headerCell('Группа', colGroup),
            _headerCell('Ссылка', colLink),
            _headerCell('Родитель', colParent),
            _headerCell('Источник', colSource),
            _headerCell('Вступления', colJoins),
            _headerCell('Действия', colActions),
          ],
        ),
      ),
    );
  }

  Widget _headerCell(String label, double width) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ),
    );
  }

  Widget _buildCatalogRow(
    BuildContext context,
    AppState state,
    MaxChannelCatalogEntry e, {
    required double rowH,
    required double colCheck,
    required double colGroup,
    required double colLink,
    required double colParent,
    required double colSource,
    required double colJoins,
    required double colActions,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
      ),
      child: SizedBox(
        height: rowH,
        child: Row(
          children: [
            SizedBox(
              width: colCheck,
              height: rowH,
              child: MouseRegion(
                onEnter: (_) {
                  if (_dragSelectTo != null) _applyDragSelect(e.chatId);
                },
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if (event.buttons == 1) {
                      _beginDragSelect(e.chatId);
                    }
                  },
                  child: ValueListenableBuilder<Set<String>>(
                    valueListenable: _selectedChatIds,
                    builder: (context, selected, _) {
                      return IgnorePointer(
                        child: Checkbox(
                          value: selected.contains(e.chatId),
                          onChanged: (_) {},
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            SizedBox(
              width: colGroup,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      e.chatId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: colLink,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: e.hasInviteLink
                    ? InkWell(
                        onTap: () => _copyLink(e),
                        child: Text(
                          e.inviteUrl!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: primary, fontSize: 12),
                        ),
                      )
                    : const Text('—', style: TextStyle(color: Colors.white38)),
              ),
            ),
            SizedBox(
              width: colParent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  _motherLabel(state, e.assignedMotherAccountId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: e.isAssigned ? null : Colors.white54,
                    fontWeight: e.isAssigned ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: colSource,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(_sourceLabel(e), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            SizedBox(
              width: colJoins,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(_joinStatus(state, e), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            SizedBox(
              width: colActions,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Назначить родителю',
                    onPressed: _busy ? null : () => _assignOne(state, e),
                    icon: const Icon(Icons.account_tree_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                  if (e.hasInviteLink)
                    IconButton(
                      tooltip: 'Копировать ссылку',
                      onPressed: () => _copyLink(e),
                      icon: const Icon(Icons.copy, size: 18),
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    tooltip: 'Удалить',
                    onPressed: _busy
                        ? null
                        : () async {
                            await state.removeCatalogGroups([e.chatId]);
                            if (!mounted) return;
                            _mutateSelection((s) => s.remove(e.chatId));
                          },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
