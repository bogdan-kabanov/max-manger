import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/account_map_state.dart';
import '../models/active_action.dart';
import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import '../models/mother_group_channel.dart';
import '../models/pipeline_journal_event.dart';
import '../providers/app_state.dart';
import '../services/max_mother_service.dart';
import '../utils/join_link_parser.dart';

enum _AssignFilter { free, mother, all }

enum _JoinFilter { all, pending, joined }

/// Soft-assign catalog groups to matkas + children join + membership visibility.
class PipelineAssignPanel extends StatefulWidget {
  const PipelineAssignPanel({super.key});

  @override
  State<PipelineAssignPanel> createState() => _PipelineAssignPanelState();
}

class _PipelineAssignPanelState extends State<PipelineAssignPanel> {
  String? _selectedMotherId;
  _AssignFilter _filter = _AssignFilter.mother;
  _JoinFilter _joinFilter = _JoinFilter.all;
  final _selectedChatIds = <String>{};
  String _query = '';
  bool _joining = false;
  bool _busy = false;
  /// For non-RU children that cannot join by link — mother joins and invites by ID.
  bool _inviteById = true;

  void _ensureMother(AppState state) {
    final mothers = _mothers(state);
    if (mothers.isEmpty) {
      _selectedMotherId = null;
      return;
    }
    if (_selectedMotherId == null ||
        !mothers.any((m) => m.id == _selectedMotherId)) {
      _selectedMotherId = mothers.first.id;
    }
  }

  List<MaxAccount> _mothers(AppState state) {
    final out = <MaxAccount>[];
    for (final c in state.motherClusters) {
      final id = c.motherAccountId;
      if (id == null) continue;
      final a = state.accountById(id);
      if (a != null) out.add(a);
    }
    return out;
  }

  MotherCluster? _clusterForMother(AppState state, String motherId) {
    for (final c in state.motherClusters) {
      if (c.motherAccountId == motherId) return c;
    }
    return null;
  }

  int _joinedChildCount(AppState state, MaxChannelCatalogEntry e) {
    final mid = e.assignedMotherAccountId ?? _selectedMotherId;
    if (mid == null) return 0;
    return state.childrenJoinedChat(motherAccountId: mid, chatId: e.chatId).length;
  }

  List<MaxChannelCatalogEntry> _filtered(AppState state) {
    var list = state.channelCatalog;
    switch (_filter) {
      case _AssignFilter.free:
        list = list.where((e) => !e.isAssigned).toList();
      case _AssignFilter.mother:
        final mid = _selectedMotherId;
        list = mid == null
            ? const []
            : list.where((e) => e.assignedMotherAccountId == mid).toList();
      case _AssignFilter.all:
        break;
    }

    if (_filter != _AssignFilter.free &&
        _selectedMotherId != null &&
        _joinFilter != _JoinFilter.all) {
      list = list.where((e) {
        final n = _joinedChildCount(state, e);
        return switch (_joinFilter) {
          _JoinFilter.pending => n == 0,
          _JoinFilter.joined => n > 0,
          _JoinFilter.all => true,
        };
      }).toList();
    }

    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (e) =>
                e.title.toLowerCase().contains(q) ||
                e.chatId.contains(q) ||
                (e.inviteHash?.toLowerCase().contains(q) ?? false) ||
                (e.inviteUrl?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    return list;
  }

  String _motherLabel(AppState state, String? motherId) {
    if (motherId == null || motherId.isEmpty) return 'свободна';
    return state.accountById(motherId)?.label ?? motherId;
  }

  String _joinStatusLine(AppState state, MaxChannelCatalogEntry e) {
    final mid = e.assignedMotherAccountId ?? _selectedMotherId;
    if (mid == null) return '';
    final cluster = _clusterForMother(state, mid);
    if (cluster == null) return '';
    final motherIn = state.accountJoinedCatalogChat(accountId: mid, entry: e);
    final motherPart = motherIn ? 'мать ✓' : 'мать —';
    final childIds = cluster.childAccountIds;
    if (childIds.isEmpty) {
      return motherPart;
    }
    final joined = <MaxAccount>[];
    for (final id in childIds) {
      if (!state.accountJoinedCatalogChat(accountId: id, entry: e)) continue;
      final a = state.accountById(id);
      if (a != null) joined.add(a);
    }
    final names = joined.map((a) => a.label).join(', ');
    if (joined.isEmpty) {
      return '$motherPart · дочки 0/${childIds.length}';
    }
    return '$motherPart · дочки ${joined.length}/${childIds.length} · $names';
  }

  Future<void> _clearJoinedMarks(AppState state) async {
    final motherId = _selectedMotherId;
    if (motherId == null || _selectedChatIds.isEmpty) return;
    final n = _selectedChatIds.length;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сбросить учёт вступлений?'),
        content: Text(
          'Убрать отметку «уже вступали» у дочек по $n выбранным каналам.\n'
          'Из MAX никто не выйдет — только локальный учёт, чтобы можно было пригласить снова.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сбросить')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final removed = await state.clearChildMembershipsForChats(
      motherAccountId: motherId,
      chatIds: _selectedChatIds,
    );
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed > 0
              ? 'Сброшено отметок: $removed'
              : 'Нечего сбрасывать — учёта по выбранным нет',
        ),
      ),
    );
  }

  Future<void> _pasteLinks(AppState state) async {
    final motherId = _selectedMotherId;
    if (motherId == null) return;
    final mother = state.accountById(motherId);
    final ctrl = TextEditingController();
    try {
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
      if (clip != null && clip.contains('max.ru/join/')) {
        ctrl.text = clip;
      }
    } catch (_) {}

    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Вставить ссылки'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Матке «${mother?.label ?? motherId}». '
                'Список https://max.ru/join/… — затем «Вступить дочками».',
                style: const TextStyle(fontSize: 12, height: 1.35),
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
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Добавить родителю'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (text == null || !mounted) return;

    final parsed = JoinLinkParser.parseHashes(text);
    if (parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не нашли ссылки max.ru/join/…')),
      );
      return;
    }

    final result = await state.importJoinLinksToMother(
      motherAccountId: motherId,
      rawText: text,
    );
    if (!mounted) return;
    setState(() {
      _filter = _AssignFilter.mother;
      _joinFilter = _JoinFilter.all;
      _selectedChatIds.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Добавлено: ${result.added}'
          '${result.alreadyKnown > 0 ? ' · уже были: ${result.alreadyKnown}' : ''}'
          ' (из ${parsed.length})',
        ),
      ),
    );
  }

  Future<void> _joinChildren(AppState state, {required bool onlySelected}) async {
    final motherId = _selectedMotherId;
    if (motherId == null || _joining) return;

    final onlyChatIds = onlySelected && _selectedChatIds.isNotEmpty
        ? Set<String>.from(_selectedChatIds)
        : null;

    final plan = state.buildPipelineLaunchPlan(
      alreadyJoinedChatIds: state.joinedChatIdsForPipeline(),
      onlyMotherId: motherId,
      onlyChatIds: onlyChatIds,
    );
    if (!plan.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(plan.error ?? 'Нечего вступать')),
      );
      return;
    }

    final modeLabel = _inviteById
        ? 'по ID (родитель войдёт и пригласит дочек)'
        : 'по ссылкам (дочки входят сами)';

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_inviteById ? 'Пригласить дочек по ID?' : 'Вступить дочками?'),
        content: Text(
          '${plan.summaryLine}\n\n'
          'Режим: $modeLabel.\n'
          '${_inviteById ? 'Нужен, если у дочек нет прав вступать по ссылке (часто не-РФ аккаунты).' : 'Дочки сами жмут join-ссылку.'}\n'
          'Каналы, куда дочки уже входили, пропускаются.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_inviteById ? 'Пригласить' : 'Вступить'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _joining = true);
    await state.addPipelineJournal(
      kind: PipelineJournalKind.launchPlan,
      message: plan.summaryLine,
      motherAccountId: motherId,
      detail: _inviteById ? 'Раздача · по ID' : 'Раздача · по ссылкам',
    );
    final action = state.beginAction(
      kind: _inviteById ? ActiveActionKind.inviteChildren : ActiveActionKind.childrenJoin,
      title: _inviteById ? 'Приглашение по ID' : 'Вступление дочек',
      subtitle: plan.summaryLine,
    );

    try {
      final message = _inviteById
          ? (await state.runPipelineChildrenJoinById(
              onlyMotherId: motherId,
              onlyChatIds: onlyChatIds,
              cancel: action.cancelToken,
              actionId: action.id,
            ))
              .message
          : (await state.runPipelineChildrenJoinByLinks(
              onlyMotherId: motherId,
              onlyChatIds: onlyChatIds,
              cancel: action.cancelToken,
              actionId: action.id,
            ))
              .message;
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
        message: message,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      setState(() => _selectedChatIds.clear());
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

  Future<void> _assign(AppState state, {required bool clear}) async {
    if (_selectedChatIds.isEmpty) return;
    final motherId = clear ? null : _selectedMotherId;
    if (!clear && motherId == null) return;

    if (!clear) {
      final conflicts = state.channelCatalog
          .where(
            (e) =>
                _selectedChatIds.contains(e.chatId) &&
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

    await state.assignCatalogGroupsToMother(
      chatIds: _selectedChatIds.toList(),
      motherAccountId: motherId,
    );
    if (!mounted) return;
    setState(() => _selectedChatIds.clear());
  }

  Future<void> _createCluster(AppState state) async {
    if (state.accounts.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала добавьте аккаунт во вкладке «Профили»')),
      );
      return;
    }

    final occupied = <String>{
      for (final c in state.motherClusters)
        if (c.motherAccountId != null) c.motherAccountId!,
      for (final c in state.motherClusters) ...c.childAccountIds,
    };
    final mothers = state.accounts.toList();
    var motherId = mothers
            .firstWhere(
              (a) => !occupied.contains(a.id),
              orElse: () => mothers.first,
            )
            .id;
    final childIds = <String>{};

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Новый кластер'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      value: motherId,
                      decoration: const InputDecoration(
                        labelText: 'Аккаунт (родитель / один)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final a in mothers)
                          DropdownMenuItem(
                            value: a.id,
                            child: Text(
                              '${a.label}${a.hasApiSession ? '' : ' · нет токена'}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setLocal(() {
                          motherId = v;
                          childIds.remove(v);
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Дочерние (необязательно — без них работает один):',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final a in mothers.where((x) => x.id != motherId))
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              value: childIds.contains(a.id),
                              title: Text(a.label, style: const TextStyle(fontSize: 13)),
                              onChanged: (v) => setLocal(() {
                                if (v == true) {
                                  childIds.add(a.id);
                                } else {
                                  childIds.remove(a.id);
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Создать')),
              ],
            );
          },
        );
      },
    );
    if (ok != true || !mounted) return;

    final cluster = await state.addMotherCluster(motherAccountId: motherId);
    await state.setMotherClusterRelations(
      clusterId: cluster.id,
      motherId: motherId,
      childIds: childIds,
    );
    if (!mounted) return;
    setState(() => _selectedMotherId = motherId);
  }

  Future<void> _editClusterChildren(AppState state) async {
    final motherId = _selectedMotherId;
    if (motherId == null) return;
    final cluster = _clusterForMother(state, motherId);
    if (cluster == null) return;

    final childIds = {...cluster.childAccountIds};
    final candidates = state.accounts.where((a) => a.id != motherId).toList();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Дочерние аккаунты'),
              content: SizedBox(
                width: 420,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: candidates.isEmpty
                      ? const Text('Нет других аккаунтов — добавьте в «Профили».')
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final a in candidates)
                              CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                value: childIds.contains(a.id),
                                title: Text(a.label, style: const TextStyle(fontSize: 13)),
                                onChanged: (v) => setLocal(() {
                                  if (v == true) {
                                    childIds.add(a.id);
                                  } else {
                                    childIds.remove(a.id);
                                  }
                                }),
                              ),
                          ],
                        ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
              ],
            );
          },
        );
      },
    );
    if (ok != true || !mounted) return;
    await state.setMotherClusterRelations(
      clusterId: cluster.id,
      motherId: motherId,
      childIds: childIds,
    );
  }

  Future<void> _leaveSelected(AppState state) async {
    if (_busy || _joining) return;
    final motherId = _selectedMotherId;
    if (motherId == null || _selectedChatIds.isEmpty) return;
    final mother = state.accountById(motherId);
    if (mother == null || !mother.hasApiSession) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('У выбранного аккаунта нет API-токена')),
      );
      return;
    }

    final chatIds = _selectedChatIds.toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из групп?'),
        content: Text(
          '«${mother.label}» выйдет из ${chatIds.length} '
          '${chatIds.length == 1 ? 'группы' : 'групп'}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Выйти')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    if (state.browser.activeAccount?.id == mother.id) {
      await state.browser.releaseWebview();
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    setState(() => _busy = true);
    final action = state.beginAction(
      kind: ActiveActionKind.leaveGroups,
      title: 'Выход из каналов',
      subtitle: '«${mother.label}» · ${chatIds.length}',
    );
    try {
      await state.ensureViewerId(mother);
      final m = state.accountById(mother.id)!;
      final result = await MaxMotherService.leaveGroups(
        token: m.apiToken!,
        chatIds: chatIds,
        delayMs: state.rateSettings.motherJoinDelayMs,
        proxy: m.isolation.proxyServer,
        onProgress: (msg) => state.updateActionProgress(action.id, message: msg),
        cancel: action.cancelToken,
      );
      final leftIds = result.results
          .where((r) => r['ok'] == true && r['chatId'] != null)
          .map((r) => r['chatId'].toString())
          .toSet();
      if (leftIds.isNotEmpty) {
        await state.removeGroupMemberships(accountId: mother.id, chatIds: leftIds);
        if (mounted) {
          setState(() => _selectedChatIds.removeWhere(leftIds.contains));
        }
      }
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : (result.ok ? ActiveActionStatus.completed : ActiveActionStatus.failed),
        message: result.message,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
      }
    } catch (e) {
      state.finishAction(action.id, status: ActiveActionStatus.failed, message: e.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifySelected(AppState state) async {
    if (_busy || _joining) return;
    final motherId = _selectedMotherId;
    if (motherId == null || _selectedChatIds.isEmpty) return;
    final mother = state.accountById(motherId);
    if (mother == null) return;

    final expected = state.channelCatalog
        .where((e) => _selectedChatIds.contains(e.chatId))
        .map(
          (e) => MotherGroupChannel(
            chatId: e.chatId,
            title: e.title,
            inviteHash: e.inviteHash,
          ),
        )
        .toList();
    if (expected.isEmpty) return;

    final cluster = _clusterForMother(state, motherId);
    final accountIds = <String>{
      mother.id,
      ...?cluster?.childAccountIds,
    };
    final withToken = state.accounts
        .where((a) => accountIds.contains(a.id) && a.hasApiSession)
        .map((a) => a.id)
        .toList();
    if (withToken.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет аккаунтов с токеном для проверки')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final summary = await state.verifyAccountsInGroups(
        accountIds: withToken,
        expectedGroups: expected,
        onLog: (msg, {String level = 'info'}) {},
      );
      if (!mounted) return;
      final msg = summary.allOk
          ? '✓ Все на месте в выбранных группах'
          : '⚠ Пропусков: ${summary.missingTotal}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureMother(state);
    final mothers = _mothers(state);
    final entries = _filtered(state);
    final scheme = Theme.of(context).colorScheme;
    final locked = _joining || _busy;
    final freeCount = state.channelCatalog.where((e) => !e.isAssigned).length;
    final assignedToSelected = _selectedMotherId == null
        ? 0
        : state.channelCatalog
            .where((e) => e.assignedMotherAccountId == _selectedMotherId)
            .length;
    final pendingCount = _selectedMotherId == null
        ? 0
        : state.channelCatalog
            .where(
              (e) =>
                  e.assignedMotherAccountId == _selectedMotherId &&
                  _joinedChildCount(state, e) == 0,
            )
            .length;
    final joinedCount = assignedToSelected - pendingCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Раздача групп',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Назначение аккаунту → вступление / проверка / выход здесь же. '
                'Дальше шаблон во вкладке «Шаблоны» и «Запуск».',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, height: 1.35),
              ),
            ],
          ),
        ),
        if (mothers.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Нет кластеров. Создайте родительский аккаунт (можно без дочерних).',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _createCluster(state),
                      icon: const Icon(Icons.add),
                      label: const Text('Создать кластер'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedMotherId,
                    decoration: const InputDecoration(
                      labelText: 'Родитель / аккаунт',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final m in mothers)
                        DropdownMenuItem(
                          value: m.id,
                          child: Text(
                            '${m.label} · ${_clusterForMother(state, m.id)?.childAccountIds.length ?? 0} дочек · '
                            '${state.channelCatalog.where((e) => e.assignedMotherAccountId == m.id).length} групп',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: locked
                        ? null
                        : (v) => setState(() {
                              _selectedMotherId = v;
                              if (_filter == _AssignFilter.mother) _selectedChatIds.clear();
                            }),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: 'Дочерние',
                  onPressed: locked || _selectedMotherId == null
                      ? null
                      : () => _editClusterChildren(state),
                  icon: const Icon(Icons.group_outlined),
                ),
                const SizedBox(width: 4),
                IconButton.outlined(
                  tooltip: 'Ещё кластер',
                  onPressed: locked ? null : () => _createCluster(state),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: Text('Свободные ($freeCount)'),
                  selected: _filter == _AssignFilter.free,
                  onSelected: locked
                      ? null
                      : (_) => setState(() {
                            _filter = _AssignFilter.free;
                            _selectedChatIds.clear();
                          }),
                ),
                FilterChip(
                  label: Text('Этот аккаунт ($assignedToSelected)'),
                  selected: _filter == _AssignFilter.mother,
                  onSelected: locked
                      ? null
                      : (_) => setState(() {
                            _filter = _AssignFilter.mother;
                            _selectedChatIds.clear();
                          }),
                ),
                FilterChip(
                  label: Text('Все (${state.channelCatalog.length})'),
                  selected: _filter == _AssignFilter.all,
                  onSelected: locked
                      ? null
                      : (_) => setState(() {
                            _filter = _AssignFilter.all;
                            _selectedChatIds.clear();
                          }),
                ),
                OutlinedButton.icon(
                  onPressed: locked || _selectedMotherId == null ? null : () => _pasteLinks(state),
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Вставить ссылки', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
          ),
          if (_filter != _AssignFilter.free) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilterChip(
                    label: const Text('Все статусы', style: TextStyle(fontSize: 11)),
                    selected: _joinFilter == _JoinFilter.all,
                    onSelected: locked ? null : (_) => setState(() => _joinFilter = _JoinFilter.all),
                  ),
                  FilterChip(
                    label: Text('Без вступлений ($pendingCount)', style: const TextStyle(fontSize: 11)),
                    selected: _joinFilter == _JoinFilter.pending,
                    onSelected: locked
                        ? null
                        : (_) => setState(() => _joinFilter = _JoinFilter.pending),
                  ),
                  FilterChip(
                    label: Text('Уже вступали ($joinedCount)', style: const TextStyle(fontSize: 11)),
                    selected: _joinFilter == _JoinFilter.joined,
                    onSelected: locked
                        ? null
                        : (_) => setState(() => _joinFilter = _JoinFilter.joined),
                  ),
                ],
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              enabled: !locked,
              decoration: const InputDecoration(
                hintText: 'Поиск…',
                isDense: true,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                TextButton(
                  onPressed: entries.isEmpty || locked
                      ? null
                      : () => setState(() {
                            _selectedChatIds
                              ..clear()
                              ..addAll(entries.map((e) => e.chatId));
                          }),
                  child: const Text('Выбрать все', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: _selectedChatIds.isEmpty || locked
                      ? null
                      : () => setState(() => _selectedChatIds.clear()),
                  child: const Text('Сбросить', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: _selectedChatIds.isEmpty || locked || _selectedMotherId == null
                      ? null
                      : () => _clearJoinedMarks(state),
                  child: const Text('Сбросить учёт', style: TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                Text(
                  'выбрано ${_selectedChatIds.length}',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _filter == _AssignFilter.free
                            ? 'Свободных нет — вставьте ссылки или спарсьте группы'
                            : _joinFilter == _JoinFilter.pending
                                ? 'Нет каналов без вступлений дочек'
                                : 'Пусто для этого фильтра',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final e = entries[index];
                      final selected = _selectedChatIds.contains(e.chatId);
                      final joinedN = _joinedChildCount(state, e);
                      return CheckboxListTile(
                        dense: true,
                        value: selected,
                        onChanged: locked
                            ? null
                            : (v) => setState(() {
                                  if (v == true) {
                                    _selectedChatIds.add(e.chatId);
                                  } else {
                                    _selectedChatIds.remove(e.chatId);
                                  }
                                }),
                        secondary: Icon(
                          joinedN > 0 ? Icons.check_circle : Icons.radio_button_unchecked,
                          size: 18,
                          color: joinedN > 0 ? Colors.greenAccent : scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${_motherLabel(state, e.assignedMotherAccountId)} · '
                          '${_joinStatusLine(state, e)}'
                          '${e.hasInviteLink ? '\n${e.inviteUrl}' : ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: joinedN > 0
                                ? Colors.greenAccent.withValues(alpha: 0.85)
                                : scheme.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                        isThreeLine: e.hasInviteLink,
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
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _inviteById,
                    onChanged: locked ? null : (v) => setState(() => _inviteById = v ?? false),
                    title: const Text(
                      'По ID (родитель войдёт и пригласит)',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      'Для дочек без прав на join по ссылке (часто не-РФ). '
                      'Выкл. — дочки входят сами по ссылке.',
                      style: TextStyle(fontSize: 11),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: locked || _selectedMotherId == null
                              ? null
                              : () => _joinChildren(
                                    state,
                                    onlySelected: _selectedChatIds.isNotEmpty,
                                  ),
                          icon: _joining
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  _inviteById ? Icons.person_add_alt_1 : Icons.group_add,
                                  size: 18,
                                ),
                          label: Text(
                            _joining
                                ? (_inviteById ? 'Приглашение…' : 'Вступление…')
                                : _inviteById
                                    ? (_selectedChatIds.isNotEmpty
                                        ? 'Пригласить по ID (${_selectedChatIds.length})'
                                        : 'Пригласить по ID (ожидают: $pendingCount)')
                                    : (_selectedChatIds.isNotEmpty
                                        ? 'Вступить дочками (${_selectedChatIds.length})'
                                        : 'Вступить дочками (ожидают: $pendingCount)'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _selectedChatIds.isEmpty ||
                                  _selectedMotherId == null ||
                                  locked
                              ? null
                              : () => _assign(state, clear: false),
                          child: const Text('Назначить'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _selectedChatIds.isEmpty || locked
                              ? null
                              : () => _assign(state, clear: true),
                          child: const Text('Снять'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _selectedChatIds.isEmpty ||
                                  _selectedMotherId == null ||
                                  locked
                              ? null
                              : () => _verifySelected(state),
                          child: const Text('Проверить'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _selectedChatIds.isEmpty ||
                                  _selectedMotherId == null ||
                                  locked
                              ? null
                              : () => _leaveSelected(state),
                          child: const Text('Выйти'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
