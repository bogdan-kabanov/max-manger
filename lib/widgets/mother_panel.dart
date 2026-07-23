import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/account_map_state.dart';
import '../models/account_group_membership.dart';
import '../models/active_action.dart';
import '../models/app_nav_page.dart';
import '../models/max_account.dart';
import '../models/mother_group_channel.dart';
import '../models/rate_settings.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';
import '../services/child_post_join_runner.dart';
import '../services/max_mother_service.dart';
import '../services/mother_invite_planner.dart';
import '../services/storage_service.dart';
import '../utils/join_link_parser.dart';

enum _MotherMode { full, motherJoin, inviteOnly, forwardOnly, forwardAndJoin, childrenJoinOnly }

class MotherPanel extends StatefulWidget {
  const MotherPanel({super.key, this.embedded = true});

  /// When true, log goes to the shared automation journal below.
  final bool embedded;

  @override
  State<MotherPanel> createState() => _MotherPanelState();
}

class _MotherPanelState extends State<MotherPanel> {
  final _linksController = TextEditingController();
  String? _activeClusterId;
  String? _motherId;
  final _childIds = <String>{};
  bool _running = false;
  bool _capturingToken = false;
  bool _cliReady = false;
  bool _loadingGroups = false;
  late final TextEditingController _delayController;
  List<MotherGroupChannel> _motherGroups = const [];
  final _selectedGroupIds = <String>{};
  String? _groupsLoadedForMotherId;
  MotherInvitePlan? _massPlan;
  bool _massLoading = false;
  bool _rateHydrated = false;
  bool _verifyingMembership = false;
  MembershipVerifySummary? _lastVerify;

  @override
  void initState() {
    super.initState();
    _delayController = TextEditingController(text: '2.5');
    MaxMotherService.isAvailable().then((v) {
      if (mounted) setState(() => _cliReady = v);
    });
  }

  @override
  void dispose() {
    _linksController.dispose();
    _delayController.dispose();
    super.dispose();
  }

  void _hydrateRateSettings(RateSettings settings) {
    if (_rateHydrated) return;
    _rateHydrated = true;
    _delayController.text = _msToSecText(settings.motherJoinDelayMs);
  }

  static String _msToSecText(int ms) {
    final sec = ms / 1000;
    if (sec == sec.roundToDouble()) return sec.round().toString();
    return sec.toStringAsFixed(1);
  }

  int _delayMsFromField(TextEditingController controller, int fallbackMs) {
    final raw = controller.text.trim().replaceAll(',', '.');
    final sec = double.tryParse(raw);
    if (sec == null) return fallbackMs;
    return (sec * 1000).round().clamp(200, 120000);
  }

  int _currentMotherDelayMs(AppState state) {
    return _delayMsFromField(_delayController, state.rateSettings.motherJoinDelayMs);
  }

  Future<void> _persistRateSettings(AppState state) async {
    final next = state.rateSettings.copyWith(
      motherJoinDelayMs: _delayMsFromField(
        _delayController,
        state.rateSettings.motherJoinDelayMs,
      ),
    );
    await state.updateRateSettings(next);
  }

  void _log(String msg, {String level = 'info'}) {
    context.read<BrowserSessionManager>().logMessage('[Матка] $msg', level: level);
    _emitMapActivity(msg);
  }

  void _applyCluster(MotherCluster? cluster) {
    _activeClusterId = cluster?.id;
    _motherId = cluster?.motherAccountId;
    _childIds
      ..clear()
      ..addAll(cluster?.childAccountIds ?? const {});
    _groupsLoadedForMotherId = null;
  }

  Future<void> _runPostJoinWrites({
    required List<MaxAccount> tokenChildren,
    required List<Map<String, dynamic>> joinResults,
    ActionCancelToken? cancel,
  }) async {
    final state = context.read<AppState>();
    final childrenOnly = tokenChildren
        .where((c) => state.canSendJoinMessages(c.id))
        .toList();
    final hasAny = childrenOnly.any((c) {
      final t = state.joinTemplateForAccount(c.id);
      return t != null && t.isActive;
    });
    if (!hasAny) return;
    if (cancel?.isCancelled == true) return;

    final action = state.beginAction(
      kind: ActiveActionKind.postJoinMessage,
      title: 'Письма после вступления',
      subtitle: '${childrenOnly.length} акк.',
    );
    try {
      final channelLinks = await state.ensureChannelInviteLinks(
        childrenOnly,
        onLog: (msg, {String level = 'info'}) => _log(msg, level: level),
        cancel: action.cancelToken,
      );
      await ChildPostJoinRunner.runFromJoinResults(
        tokenChildren: childrenOnly,
        joinResults: joinResults,
        templateFor: (child) => state.joinTemplateForAccount(child.id),
        channelLinkFor: (child) =>
            channelLinks[child.id] ??
            state.channelPolicyFor(child.id).lastCreatedInviteUrl,
        onChatsSent: (child, chatIds, {messageIdsByChatId = const {}, titleByChatId = const {}}) =>
            state.rememberTemplateSends(
          child: child,
          chatIds: chatIds,
          messageIdsByChatId: messageIdsByChatId,
          titleByChatId: titleByChatId,
        ),
        rateSettings: state.rateSettings,
        onLog: _log,
        cancel: action.cancelToken,
        onProgress: (message, {int? done, int? total}) {
          state.updateActionProgress(action.id, message: message, done: done, total: total);
        },
      );
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
      );
    } catch (e) {
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
    }
  }

  Future<void> _writeNowToSelectedChats() async {
    final state = context.read<AppState>();
    final children = state.accounts
        .where(
          (a) =>
              _childIds.contains(a.id) &&
              a.hasApiSession &&
              state.canSendJoinMessages(a.id),
        )
        .toList();
    if (children.isEmpty) {
      _failPrepare('Отметьте дочерних с токеном');
      return;
    }
    final withTemplate = children.where((c) {
      final t = state.joinTemplateForAccount(c.id);
      return t != null && t.isActive;
    }).toList();
    if (withTemplate.isEmpty) {
      _failPrepare('Назначьте шаблон дочерним во вкладке «Шаблоны»');
      return;
    }
    final chatIds = _motherGroups
        .where((g) => _selectedGroupIds.contains(g.chatId))
        .map((g) => g.chatId)
        .toList();
    if (chatIds.isEmpty) {
      _failPrepare('Выберите каналы матки, куда писать');
      return;
    }
    setState(() => _running = true);
    final action = state.beginAction(
      kind: ActiveActionKind.postJoinMessage,
      title: 'Письма в выбранные каналы',
      subtitle: '${withTemplate.length} акк. · ${chatIds.length} чатов',
    );
    try {
      final channelLinks = await state.ensureChannelInviteLinks(
        withTemplate,
        onLog: (msg, {String level = 'info'}) => _log(msg, level: level),
        cancel: action.cancelToken,
      );
      await ChildPostJoinRunner.runToChatIds(
        children: withTemplate,
        chatIds: chatIds,
        templateFor: (child) => state.joinTemplateForAccount(child.id),
        channelLinkFor: (child) =>
            channelLinks[child.id] ??
            state.channelPolicyFor(child.id).lastCreatedInviteUrl,
        onChatsSent: (child, sentChatIds, {messageIdsByChatId = const {}, titleByChatId = const {}}) =>
            state.rememberTemplateSends(
          child: child,
          chatIds: sentChatIds,
          messageIdsByChatId: messageIdsByChatId,
          titleByChatId: titleByChatId,
        ),
        delayBeforeMs: 0,
        rateSettings: state.rateSettings,
        onLog: _log,
        cancel: action.cancelToken,
        onProgress: (message, {int? done, int? total}) {
          state.updateActionProgress(action.id, message: message, done: done, total: total);
        },
      );
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
      );
    } catch (e) {
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _ensureActiveCluster(AppState state) {
    final clusters = state.motherClusters;
    if (clusters.isEmpty) {
      if (_activeClusterId != null || _motherId != null || _childIds.isNotEmpty) {
        _applyCluster(null);
      }
      return;
    }
    final active = state.accountMap.clusterById(_activeClusterId ?? '');
    if (active == null) {
      _applyCluster(clusters.first);
      return;
    }
    // Keep local edits while editing; only resync mother/children if cluster id matches
    // but local ids drifted from deleted accounts.
    final accountIds = state.accounts.map((a) => a.id).toSet();
    if (_motherId != null && !accountIds.contains(_motherId)) {
      _motherId = active.motherAccountId;
    }
    _childIds.removeWhere((id) => !accountIds.contains(id) || id == _motherId);
  }

  void _syncMapRelations() {
    final clusterId = _activeClusterId;
    if (clusterId == null) return;
    context.read<AppState>().setMotherClusterRelations(
          clusterId: clusterId,
          motherId: _motherId,
          childIds: _childIds,
          clearMother: _motherId == null,
        );
  }

  Future<void> _addCluster() async {
    final state = context.read<AppState>();
    final cluster = await state.addMotherCluster();
    if (!mounted) return;
    setState(() => _applyCluster(cluster));
    _log('Создана «${cluster.name}»');
  }

  Future<void> _deleteActiveCluster() async {
    final clusterId = _activeClusterId;
    if (clusterId == null) return;
    final state = context.read<AppState>();
    final cluster = state.accountMap.clusterById(clusterId);
    final name = cluster?.name ?? 'Матка';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить матку?'),
        content: Text('«$name» будет удалена. Аккаунты останутся, связи сбросятся.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await state.removeMotherCluster(clusterId);
    if (!mounted) return;
    setState(() {
      final next = state.motherClusters.isNotEmpty ? state.motherClusters.first : null;
      _applyCluster(next);
    });
    _log('Удалена «$name»');
  }

  Future<void> _renameActiveCluster() async {
    final clusterId = _activeClusterId;
    if (clusterId == null) return;
    final state = context.read<AppState>();
    final cluster = state.accountMap.clusterById(clusterId);
    if (cluster == null) return;
    final controller = TextEditingController(text: cluster.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Название матки'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await state.updateMotherCluster(cluster.copyWith(name: name));
  }

  void _selectCluster(MotherCluster cluster) {
    if (_activeClusterId == cluster.id) return;
    setState(() => _applyCluster(cluster));
  }

  Map<String, List<MotherGroupChannel>> _groupsByMotherId(AppState state) {
    final map = <String, List<MotherGroupChannel>>{};
    for (final cluster in state.motherClusters) {
      final motherId = cluster.motherAccountId;
      if (motherId == null) continue;
      map[motherId] = StorageService.instance.motherGroupsFor(motherId);
    }
    return map;
  }

  MotherInvitePlan _computeMassPlan(AppState state) {
    return MotherInvitePlanner.build(
      clusters: state.motherClusters,
      accounts: state.accounts,
      groupsByMotherId: _groupsByMotherId(state),
    );
  }

  Future<void> _ensureChildViewerIds(AppState state, {int limit = 40}) async {
    final motherIds = state.accountMap.allMotherAccountIds;
    final children = state.accounts
        .where((a) => !motherIds.contains(a.id) && a.hasApiSession && a.viewerId == null)
        .take(limit)
        .toList();
    for (final account in children) {
      await state.ensureViewerId(account);
      _log('viewer id «${account.label}»…');
    }
  }

  Future<void> _loadMotherGroupsCore(AppState state, List<MaxAccount> mothers) async {
    for (var i = 0; i < mothers.length; i++) {
      final mother = mothers[i];
      _log('[${i + 1}/${mothers.length}] каналы «${mother.label}»…');
      await state.ensureViewerId(mother);
      final fresh = state.accountById(mother.id)!;
      final result = await MaxMotherService.listMotherGroups(
        token: fresh.apiToken!,
        scanMessages: true,
        proxy: fresh.isolation.proxyServer,
        onProgress: _log,
      );
      if (!mounted) return;
      if (result.ok) {
        await _persistGroups(mother.id, result.groups);
        _log('«${mother.label}»: ${result.groups.length} каналов');
      } else {
        _log('✗ «${mother.label}»: ${result.message}', level: 'warn');
      }
    }
  }

  Future<void> _loadAllMotherGroups() async {
    final state = context.read<AppState>();
    final mothers = <MaxAccount>[];
    for (final cluster in state.motherClusters) {
      final id = cluster.motherAccountId;
      if (id == null) continue;
      final mother = state.accountById(id);
      if (mother != null && mother.hasApiSession) mothers.add(mother);
    }
    if (mothers.isEmpty) {
      _log('Нет маток с токеном');
      return;
    }

    setState(() {
      _massLoading = true;
      _loadingGroups = true;
    });
    _log('Загружаем каналы ${mothers.length} маток…');
    try {
      await _loadMotherGroupsCore(state, mothers);
      await _ensureChildViewerIds(state);
      if (!mounted) return;
      setState(() {
        _groupsLoadedForMotherId = null;
        _massPlan = _computeMassPlan(state);
      });
      _log(_massPlan?.summaryLine ?? 'План пуст');
    } finally {
      if (mounted) {
        setState(() {
          _massLoading = false;
          _loadingGroups = false;
        });
      }
    }
  }

  Future<void> _applyPlanToClusters(AppState state, MotherInvitePlan plan) async {
    for (final summary in plan.motherSummaries) {
      await state.setMotherClusterRelations(
        clusterId: summary.clusterId,
        motherId: summary.mother.id,
        childIds: summary.children.map((c) => c.id).toSet(),
      );
    }
  }

  Future<void> _runMassProportionalInvite() async {
    final state = context.read<AppState>();
    if (_running || _massLoading) return;
    await _persistRateSettings(state);

    setState(() {
      _running = true;
      _massLoading = true;
    });
    final action = state.beginAction(
      kind: ActiveActionKind.massInvite,
      title: 'Массовый набор',
      subtitle: 'Пропорциональные приглашения',
    );
    try {
      final mothersNeedingGroups = <MaxAccount>[];
      for (final cluster in state.motherClusters) {
        final id = cluster.motherAccountId;
        if (id == null) continue;
        final mother = state.accountById(id);
        if (mother == null || !mother.hasApiSession) continue;
        if (StorageService.instance.motherGroupsFor(id).isEmpty) {
          mothersNeedingGroups.add(mother);
        }
      }
      if (mothersNeedingGroups.isNotEmpty) {
        _log('Сначала подгружаем каналы ${mothersNeedingGroups.length} маток…');
        await _loadMotherGroupsCore(state, mothersNeedingGroups);
      }
      await _ensureChildViewerIds(state);
      if (!mounted) return;

      final plan = _computeMassPlan(state);
      setState(() {
        _massPlan = plan;
        _groupsLoadedForMotherId = null;
      });
      if (!plan.ok) {
        _failPrepare(plan.error ?? 'Нечего запускать');
        state.finishAction(
          action.id,
          status: ActiveActionStatus.failed,
          message: plan.error ?? 'Нечего запускать',
        );
        return;
      }

      _log(plan.summaryLine);
      for (final s in plan.motherSummaries) {
        _log(
          '«${s.clusterName}» / ${s.mother.label}: ${s.accountCount} акк → '
          '${s.groupCount} групп (${s.inviteCount} приглаш.)',
        );
      }

      await _applyPlanToClusters(state, plan);
      if (_activeClusterId != null) {
        final active = state.accountMap.clusterById(_activeClusterId!);
        if (active != null) setState(() => _applyCluster(active));
      }

      final delayMs = _currentMotherDelayMs(state);
      final byMother = <String, List<MotherInviteSlot>>{};
      for (final slot in plan.slots) {
        byMother.putIfAbsent(slot.mother.id, () => []).add(slot);
      }

      state.updateActionProgress(
        action.id,
        message: plan.summaryLine,
        done: 0,
        total: plan.slots.length,
      );

      var motherIndex = 0;
      var slotDone = 0;
      for (final entry in byMother.entries) {
        if (action.cancelToken.isCancelled) break;
        motherIndex++;
        final slots = entry.value;
        final mother = slots.first.mother;
        final fresh = state.accountById(mother.id) ?? mother;
        if (!fresh.hasApiSession) {
          _log('✗ Пропуск «${mother.label}»: нет токена', level: 'warn');
          continue;
        }

        _log('[$motherIndex/${byMother.length}] матка «${fresh.label}»: ${slots.length} групп');
        for (var i = 0; i < slots.length; i++) {
          if (action.cancelToken.isCancelled) break;
          final slot = slots[i];
          final inviteIds = <int>[];
          for (final child in slot.children) {
            final id = child.viewerId ?? state.accountById(child.id)?.viewerId;
            if (id != null) inviteIds.add(id);
          }
          if (inviteIds.isEmpty) {
            _log('  · «${slot.group.title}»: нет viewer id', level: 'warn');
            slotDone += 1;
            continue;
          }

          _log(
            '  · [${i + 1}/${slots.length}] «${slot.group.title}» ← ${inviteIds.length} акк',
          );
          final childTargets = <Map<String, dynamic>>[];
          for (final child in slot.children) {
            final freshChild = state.accountById(child.id) ?? child;
            final id = freshChild.viewerId ?? child.viewerId;
            if (id == null || !freshChild.hasApiSession) continue;
            final childProxy = freshChild.isolation.proxyServer?.trim();
            childTargets.add({
              'userId': id,
              'token': freshChild.apiToken!,
              if (freshChild.phone != null) 'phone': freshChild.phone!,
              if (childProxy != null && childProxy.isNotEmpty) 'proxy': childProxy,
            });
          }
          final result = await MaxMotherService.inviteChildren(
            motherToken: fresh.apiToken!,
            links: const [],
            chatIds: [slot.group.chatId],
            groups: [
              {
                'chatId': slot.group.chatId,
                'title': slot.group.title,
                if (slot.group.inviteHash != null) 'hash': slot.group.inviteHash,
              },
            ],
            inviteUserIds: inviteIds,
            childTargets: childTargets,
            delayMs: delayMs,
            proxy: fresh.isolation.proxyServer,
            onProgress: _log,
            cancel: action.cancelToken,
          );
          slotDone += 1;
          state.updateActionProgress(
            action.id,
            message: '«${fresh.label}» · ${slot.group.title}',
            done: slotDone,
            total: plan.slots.length,
          );
          if (result.ok) {
            _log(
              '    ✓ invite=${result.invited}, пересылка=${result.forwarded}, '
              'вход=${result.joined}',
            );
          } else {
            _log('    ✗ ${result.message}', level: 'warn');
          }
        }
      }

      if (action.cancelToken.isCancelled) {
        _log('Массовый набор остановлен', level: 'warn');
      } else {
        _log(
          'Готово: ${plan.childAssigned} акк / ${plan.mothersReady} маток / '
          '${plan.totalInvites} приглашений',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Набор: ${plan.childAssigned} акк → ${plan.mothersReady} маток '
                '(${plan.totalInvites} приглаш.)',
              ),
            ),
          );
        }
      }
    } finally {
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
      );
      if (mounted) {
        setState(() {
          _running = false;
          _massLoading = false;
        });
      }
    }
  }

  void _emitMapActivity(String msg) {
    final state = context.read<AppState>();
    final motherId = _motherId;
    if (motherId == null) return;

    AccountMapActivityType? type;
    String? childId;

    if (msg.contains('[Пересылка]')) {
      type = AccountMapActivityType.forwardLink;
      childId = _childIds.isNotEmpty ? _childIds.first : null;
    } else if (msg.contains('[Дочерний') && msg.contains('✓')) {
      type = AccountMapActivityType.childJoin;
      childId = _childIds.isNotEmpty ? _childIds.first : null;
    } else if (msg.contains('✗') || msg.contains('ошиб')) {
      type = AccountMapActivityType.error;
      childId = _childIds.isNotEmpty ? _childIds.first : null;
    } else if (msg.contains('приглаш')) {
      type = AccountMapActivityType.invite;
      childId = _childIds.isNotEmpty ? _childIds.first : null;
    }

    if (type == null) return;
    state.recordMapActivity(
      fromAccountId: motherId,
      toAccountId: childId,
      type: type,
      message: msg.replaceAll('[Матка] ', ''),
    );
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text?.isNotEmpty == true) {
      _linksController.text = data!.text!;
      setState(() {});
    }
  }

  MaxAccount? _mother(AppState state) => state.accountById(_motherId);

  void _loadStoredGroups(String? motherId) {
    if (motherId == null) {
      _motherGroups = const [];
      _selectedGroupIds.clear();
      return;
    }
    _motherGroups = StorageService.instance.motherGroupsFor(motherId);
    _selectedGroupIds
      ..clear()
      ..addAll(_motherGroups.map((g) => g.chatId));
  }

  Future<void> _persistGroups(String motherId, List<MotherGroupChannel> groups) async {
    if (groups.isEmpty) return;
    await StorageService.instance.mergeMotherGroups(motherId, groups);
    if (!mounted || _motherId != motherId) return;
    setState(() => _motherGroups = StorageService.instance.motherGroupsFor(motherId));
  }

  Future<void> _leaveSelectedGroups() async {
    final state = context.read<AppState>();
    await _persistRateSettings(state);
    final mother = _mother(state);
    if (mother == null || !mother.hasApiSession) {
      _failPrepare('У матки нет API-токена');
      return;
    }

    final selected = _motherGroups.where((g) => _selectedGroupIds.contains(g.chatId)).toList();
    if (selected.isEmpty) {
      _failPrepare('Отметьте каналы, из которых выйти');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из групп?'),
        content: Text(
          'Матка «${mother.label}» выйдет из ${selected.length} '
          '${selected.length == 1 ? 'группы' : 'групп'}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Выйти')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final delay = _currentMotherDelayMs(state);
    final proxy = mother.isolation.proxyServer;
    final chatIds = selected.map((g) => g.chatId).toList();

    if (state.browser.activeAccount?.id == mother.id) {
      _log('⚠ Матка открыта в MAX — закрываем браузер, иначе API-сессия оборвётся');
      await state.browser.releaseWebview();
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    setState(() => _running = true);
    _log('─── Выход матки из ${chatIds.length} групп ───');
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
        delayMs: delay,
        proxy: proxy,
        onProgress: (msg) {
          _log(msg);
          state.updateActionProgress(action.id, message: msg);
        },
        cancel: action.cancelToken,
      );

      final leftIds = result.results
          .where((r) => r['ok'] == true && r['chatId'] != null)
          .map((r) => r['chatId'].toString())
          .toSet();
      if (leftIds.isNotEmpty) {
        await StorageService.instance.removeMotherGroups(mother.id, leftIds);
        await state.removeGroupMemberships(accountId: mother.id, chatIds: leftIds);
        if (mounted && _motherId == mother.id) {
          setState(() {
            _motherGroups = StorageService.instance.motherGroupsFor(mother.id);
            _selectedGroupIds.removeWhere(leftIds.contains);
          });
        }
      }
      if (mounted) {
        _log(result.ok ? '✓ ${result.message}' : '✗ ${result.message}');
      }
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : (result.ok ? ActiveActionStatus.completed : ActiveActionStatus.failed),
        message: result.message,
      );
    } catch (e) {
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _refreshMotherGroups({bool scanMessages = true}) async {
    final state = context.read<AppState>();
    final mother = _mother(state);
    if (mother == null || !mother.hasApiSession) {
      _log('У матки нет API-токена');
      return;
    }

    setState(() => _loadingGroups = true);
    _log('Загружаем каналы матки…');
    try {
      await state.ensureViewerId(mother);
      final fresh = state.accountById(mother.id)!;
      final result = await MaxMotherService.listMotherGroups(
        token: fresh.apiToken!,
        scanMessages: scanMessages,
        proxy: fresh.isolation.proxyServer,
        onProgress: _log,
      );
      if (!mounted) return;
      if (result.ok) {
        await _persistGroups(mother.id, result.groups);
        await state.syncMembershipsFromListedGroups(
          accountId: mother.id,
          listed: result.groups,
        );
        setState(() {
          _selectedGroupIds
            ..clear()
            ..addAll(_motherGroups.map((g) => g.chatId));
        });
        final withLink = _motherGroups.where((g) => g.hasInviteLink).length;
        _log('Каналов: ${_motherGroups.length}, со ссылкой: $withLink');
      } else {
        _log('✗ ${result.message}');
      }
    } finally {
      if (mounted) setState(() => _loadingGroups = false);
    }
  }

  Future<void> _scanSelectedGroupLinks() async {
    final state = context.read<AppState>();
    final mother = _mother(state);
    if (mother == null || !mother.hasApiSession) return;

    final chatIds = _motherGroups
        .where((g) => _selectedGroupIds.contains(g.chatId))
        .map((g) => g.chatId)
        .toList();
    if (chatIds.isEmpty) {
      _log('Отметьте каналы для получения ссылок');
      return;
    }

    setState(() => _loadingGroups = true);
    _log('Берём invite-ссылки из профиля ${chatIds.length} каналов…');
    try {
      final fresh = state.accountById(mother.id)!;
      final result = await MaxMotherService.fetchProfileInviteLinks(
        token: fresh.apiToken!,
        chatIds: chatIds,
        proxy: fresh.isolation.proxyServer,
        onProgress: _log,
      );
      if (!mounted) return;
      if (result.ok) {
        await _persistGroups(mother.id, result.groups);
        final found = result.groups.where((g) => g.hasInviteLink).length;
        _log('Ссылок из профиля: $found/${chatIds.length}');
      } else {
        _log('✗ ${result.message}');
      }
    } finally {
      if (mounted) setState(() => _loadingGroups = false);
    }
  }

  void _failPrepare(String message) {
    _log(message);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  bool _modeNeedsPreFetchProfile(_MotherMode mode) {
    if (mode == _MotherMode.motherJoin || mode == _MotherMode.full) return false;
    return _modeNeedsChildProfileLinks(mode, hasManualLink: false);
  }

  bool _modeNeedsChildProfileLinks(_MotherMode mode, {required bool hasManualLink}) {
    if (mode == _MotherMode.motherJoin) return false;
    if (hasManualLink) return false;
    return mode == _MotherMode.full ||
        mode == _MotherMode.inviteOnly ||
        mode == _MotherMode.forwardOnly ||
        mode == _MotherMode.forwardAndJoin ||
        mode == _MotherMode.childrenJoinOnly;
  }

  Future<List<MotherGroupChannel>?> _fetchProfileLinksForChildren(
    MaxAccount mother,
    List<String> chatIds,
  ) async {
    if (chatIds.isEmpty) return const [];
    final state = context.read<AppState>();
    final fresh = state.accountById(mother.id)!;
    _log('Авто: invite-ссылки из профиля каналов (${chatIds.length})…');
    final result = await MaxMotherService.fetchProfileInviteLinks(
      token: fresh.apiToken!,
      chatIds: chatIds,
      groups: _motherGroups
          .where((g) => chatIds.contains(g.chatId))
          .map((g) => {
                'chatId': g.chatId,
                'title': g.title,
                if (g.inviteHash != null) 'hash': g.inviteHash,
              })
          .toList(),
      proxy: fresh.isolation.proxyServer,
      onProgress: _log,
    );
    if (!result.ok) {
      _log('✗ ${result.message}');
      return null;
    }
    await _persistGroups(mother.id, result.groups);
    final withLink = result.groups.where((g) => g.hasInviteLink).length;
    final byId = result.groups.length - withLink;
    _log('Каналов: ${result.groups.length}, по ссылке: $withLink, по ID: $byId');
    return result.groups;
  }

  Future<void> _captureChildToken(MaxAccount child) async {
    final state = context.read<AppState>();
    setState(() => _capturingToken = true);
    _log('Читаем токен «${child.label}» из браузера…');
    try {
      final ok = await state.captureTokenFromBrowser(child);
      if (!mounted) return;
      if (ok) {
        _log('✓ Токен «${child.label}» сохранён');
      } else {
        _log('Откройте «${child.label}» в MAX слева и повторите');
      }
    } finally {
      if (mounted) setState(() => _capturingToken = false);
    }
  }

  Future<void> _captureToken() async {
    final state = context.read<AppState>();
    final mother = _mother(state);
    if (mother == null) return;

    setState(() => _capturingToken = true);
    _log('Читаем токен из браузера «${mother.label}»…');
    try {
      final ok = await state.captureTokenFromBrowser(mother);
      if (!mounted) return;
      if (ok) {
        _log('✓ Токен сохранён для «${mother.label}»');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Токен «${mother.label}» сохранён')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Откройте аккаунт в MAX слева и дождитесь загрузки, затем повторите'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _capturingToken = false);
    }
  }

  Future<
      ({
        List<String> urls,
        List<String> manualUrls,
        List<Map<String, dynamic>> groups,
        List<String> inviteChatIds,
        List<MaxAccount> children,
      })?> _prepareRun(_MotherMode mode) async {
    final state = context.read<AppState>();
    final mother = _mother(state);
    if (mother == null) {
      _failPrepare('Выберите аккаунт-матку');
      return null;
    }

    final manualHashes = JoinLinkParser.parseHashes(_linksController.text);
    final manualUrls = JoinLinkParser.toUrls(manualHashes);
    final hasManualLink = manualUrls.isNotEmpty;

    final selectedGroups =
        _motherGroups.where((g) => _selectedGroupIds.contains(g.chatId)).toList();
    final inviteChatIds = selectedGroups.map((g) => g.chatId).toList();

    if (mode == _MotherMode.motherJoin) {
      if (!hasManualLink) {
        _failPrepare('Вставьте ссылку — только матка вступит в канал по ней');
        return null;
      }
    }

    if (mode == _MotherMode.full) {
      if (!hasManualLink && selectedGroups.isEmpty) {
        _failPrepare('Вставьте ссылку для матки или выберите каналы');
        return null;
      }
    }

    if (_modeNeedsChildProfileLinks(mode, hasManualLink: hasManualLink)) {
      if (selectedGroups.isEmpty) {
        _failPrepare('Выберите каналы матки — дочерним уйдёт ссылка из профиля канала');
        return null;
      }
    }

    if ((mode == _MotherMode.forwardOnly ||
            mode == _MotherMode.forwardAndJoin ||
            mode == _MotherMode.childrenJoinOnly) &&
        selectedGroups.isEmpty &&
        !hasManualLink) {
      _failPrepare('Вставьте доп. ссылку max.ru/join/… — или выберите каналы матки');
      return null;
    }

    List<MotherGroupChannel> childProfileGroups = const [];
    if (_modeNeedsPreFetchProfile(mode) && selectedGroups.isNotEmpty) {
      final fetched = await _fetchProfileLinksForChildren(mother, inviteChatIds);
      if (fetched == null) {
        _failPrepare('Не удалось прочитать каналы матки');
        return null;
      }
      childProfileGroups = fetched;
    }

    final groupsForPayload = childProfileGroups.isNotEmpty ? childProfileGroups : selectedGroups;
    final groupPayload = groupsForPayload
        .map((g) => {
              'chatId': g.chatId,
              'title': g.title,
              'hash': g.inviteHash,
              'inviteUrl': g.inviteUrl,
              'type': g.type ?? 'CHAT',
            })
        .toList();

    final childHashes = childProfileGroups
        .map((g) => g.inviteHash)
        .whereType<String>()
        .where((h) => h.isNotEmpty)
        .toSet();
    // Extra pasted links are additive — join another channel without clearing mother channels.
    final urls = [
      ...{...manualHashes, ...childHashes}.map((h) => 'https://max.ru/join/$h'),
    ];

    if (mode == _MotherMode.inviteOnly && selectedGroups.isEmpty && !hasManualLink) {
      _failPrepare('Выберите каналы матки');
      return null;
    }

    if (mode != _MotherMode.childrenJoinOnly) {
      if (!mother.hasApiSession) {
        _failPrepare('У «${mother.label}» нет токена — нажмите «Взять токен из MAX»');
        return null;
      }
    }

    final selectedChildren = state.accounts
        .where((a) => a.id != mother.id && _childIds.contains(a.id))
        .toList();
    final children = selectedChildren.where((a) => a.hasApiSession).toList();

    if (mode == _MotherMode.inviteOnly && selectedChildren.isEmpty) {
      _failPrepare('Отметьте дочерние аккаунты для приглашения');
      return null;
    }
    if ((mode == _MotherMode.forwardOnly || mode == _MotherMode.forwardAndJoin) &&
        selectedChildren.isEmpty) {
      _failPrepare('Отметьте дочерние аккаунты для пересылки ссылок');
      return null;
    }
    if (mode == _MotherMode.childrenJoinOnly && selectedChildren.isEmpty) {
      _failPrepare('Отметьте дочерние аккаунты (нужен токен)');
      return null;
    }
    if ((mode == _MotherMode.forwardAndJoin || mode == _MotherMode.childrenJoinOnly) &&
        selectedChildren.any((a) => !a.hasApiSession)) {
      final names = selectedChildren.where((a) => !a.hasApiSession).map((a) => a.label).join(', ');
      _failPrepare('Нет API-токена у: $names. Откройте в MAX слева → кнопка «Токен»');
      return null;
    }
    if ((mode == _MotherMode.forwardAndJoin || mode == _MotherMode.childrenJoinOnly) &&
        children.isEmpty) {
      _failPrepare('У дочерних нет токена — нажмите «Токен» у каждого');
      return null;
    }

    if ((mode == _MotherMode.full ||
            mode == _MotherMode.forwardAndJoin ||
            mode == _MotherMode.forwardOnly ||
            mode == _MotherMode.childrenJoinOnly) &&
        selectedChildren.isEmpty) {
      _failPrepare('Отметьте дочерние аккаунты в списке ниже');
      return null;
    }

    return (
      urls: urls,
      manualUrls: manualUrls,
      groups: groupPayload,
      inviteChatIds: inviteChatIds,
      children: children,
    );
  }

  Future<void> _afterRun(
    MotherJoinResult result,
    String motherId, {
    List<MaxAccount> children = const [],
  }) async {
    if (result.groups.isNotEmpty) {
      await _persistGroups(motherId, result.groups);
    }
    final titleByChatId = <String, String>{
      for (final g in _motherGroups) g.chatId: g.title,
      for (final g in result.groups) g.chatId: g.title,
    };
    final state = context.read<AppState>();
    await state.recordMembershipsFromJoinResults(
      motherAccountId: motherId,
      children: children,
      results: result.results,
      titleByChatId: titleByChatId,
    );
  }

  Future<void> _verifyMemberships() async {
    final state = context.read<AppState>();
    final mother = _mother(state);
    if (mother == null) return;

    final expected = _motherGroups
        .where((g) => _selectedGroupIds.contains(g.chatId))
        .toList();
    if (expected.isEmpty) {
      _failPrepare('Выберите группы для проверки');
      return;
    }

    final accountIds = <String>{
      mother.id,
      ..._childIds,
    };
    final withToken = state.accounts
        .where((a) => accountIds.contains(a.id) && a.hasApiSession)
        .map((a) => a.id)
        .toList();
    if (withToken.isEmpty) {
      _failPrepare('Нет аккаунтов с токеном для проверки');
      return;
    }

    setState(() {
      _verifyingMembership = true;
      _running = true;
    });
    _log('─── Проверка вступлений: ${expected.length} групп · ${withToken.length} акк. ───');
    try {
      final summary = await state.verifyAccountsInGroups(
        accountIds: withToken,
        expectedGroups: expected,
        onLog: _log,
      );
      if (!mounted) return;
      setState(() => _lastVerify = summary);
      if (summary.allOk) {
        _log('✓ Все проверенные аккаунты на месте в выбранных группах');
      } else {
        _log(
          '⚠ Пропусков: ${summary.missingTotal} (акк. с ошибками/без группы)',
          level: 'warn',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _verifyingMembership = false;
          _running = false;
        });
      }
    }
  }

  Future<void> _confirmJoinLinksInChildBrowser({
    required List<String> urls,
    required List<MaxAccount> children,
  }) async {
    if (urls.isEmpty || children.isEmpty || !mounted) return;

    final state = context.read<AppState>();
    final browser = context.read<BrowserSessionManager>();
    final child = children.first;

    _log('Открываем ссылку у «${child.label}» — авто-подтверждение правил…');
    state.setBrowserDrawerOpen(true);
    await state.selectAccount(child);
    await browser.openAccount(child);

    for (final url in urls.take(5)) {
      await browser.openJoinLinkAndConfirm(url);
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  Future<void> _runMode(_MotherMode mode) async {
    final state = context.read<AppState>();
    await _persistRateSettings(state);
    _log('Подготовка…');
    final prepared = await _prepareRun(mode);
    if (prepared == null) return;

    final mother = _mother(state)!;
    final delay = _currentMotherDelayMs(state);

    if (state.browser.activeAccount?.id == mother.id) {
      _log('⚠ Матка открыта в MAX — закрываем браузер, иначе API-сессия оборвётся');
      await state.browser.releaseWebview();
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    setState(() => _running = true);

    final modeKind = switch (mode) {
      _MotherMode.full => ActiveActionKind.motherDeploy,
      _MotherMode.motherJoin => ActiveActionKind.joinChannels,
      _MotherMode.inviteOnly => ActiveActionKind.inviteChildren,
      _MotherMode.forwardOnly => ActiveActionKind.forwardLinks,
      _MotherMode.forwardAndJoin => ActiveActionKind.forwardAndJoin,
      _MotherMode.childrenJoinOnly => ActiveActionKind.childrenJoin,
    };
    final modeLabel = switch (mode) {
      _MotherMode.full => 'полный цикл',
      _MotherMode.motherJoin => 'только вступление матки',
      _MotherMode.inviteOnly => 'приглашение по ID',
      _MotherMode.forwardOnly => 'пересылка ссылок',
      _MotherMode.forwardAndJoin => 'переслать и вступить',
      _MotherMode.childrenJoinOnly => 'дочерние по ссылкам',
    };
    final action = state.beginAction(
      kind: modeKind,
      title: modeKind.label,
      subtitle: '«${mother.label}» · $modeLabel',
    );
    void trackProgress(String msg) {
      _log(msg);
      state.updateActionProgress(action.id, message: msg);
    }

    _log('─── Старт: $modeLabel ───');
    _log('Матка: «${mother.label}» viewerId=${mother.viewerId ?? "?"} token=${mother.hasApiSession}');
    _log('Каналы (${prepared.inviteChatIds.length}): ${prepared.inviteChatIds.join(", ")}');
    for (final g in prepared.groups) {
      final title = g['title'] ?? g['chatId'];
      final hash = g['hash']?.toString();
      final hashPreview = hash != null && hash.isNotEmpty
          ? '${hash.substring(0, hash.length > 14 ? 14 : hash.length)}…'
          : 'нет';
      _log('  · $title chatId=${g['chatId']} hash=$hashPreview');
    }
    _log('Ссылки вручную: ${prepared.manualUrls.length}');
    for (final child in prepared.children) {
      _log('Дочерний: «${child.label}» id=${child.viewerId ?? "?"} phone=${child.phone ?? "нет"} token=${child.hasApiSession}');
    }
    if (mode == _MotherMode.full) {
      _log('Каскад: по ID → пересылка → вступление дочернего, пауза=$delayмс');
    }
    _log('Старт ($modeLabel): «${mother.label}», ссылок: ${prepared.urls.length}');
    final proxy = mother.isolation.proxyServer;
    if (proxy != null && proxy.trim().isNotEmpty) {
      _log('Прокси матки: задан (API не с вашего IP)');
    }

    try {
      MotherJoinResult result;

      if (mode == _MotherMode.motherJoin) {
        await state.ensureViewerId(mother);
        final m = state.accountById(mother.id)!;
        result = await MaxMotherService.joinGroups(
          token: m.apiToken!,
          links: prepared.manualUrls,
          delayMs: delay,
          proxy: proxy,
          onProgress: trackProgress,
          cancel: action.cancelToken,
        );
        await _afterRun(result, mother.id, children: prepared.children);
      } else if (mode == _MotherMode.inviteOnly) {
        await state.ensureViewerId(mother);
        final m = state.accountById(mother.id)!;
        final inviteIds = <int>[];
        final childTargets = <Map<String, dynamic>>[];
        for (final child in prepared.children) {
          final id = await state.ensureViewerId(child);
          final fresh = state.accountById(child.id)!;
          if (id != null) inviteIds.add(id);
          if (id != null && fresh.hasApiSession) {
            final childProxy = fresh.isolation.proxyServer?.trim();
            childTargets.add({
              'userId': id,
              'token': fresh.apiToken!,
              if (fresh.phone != null) 'phone': fresh.phone!,
              if ((childProxy != null && childProxy.isNotEmpty) ||
                  (proxy != null && proxy.trim().isNotEmpty))
                'proxy': (childProxy != null && childProxy.isNotEmpty)
                    ? childProxy
                    : proxy!.trim(),
            });
          }
        }
        if (inviteIds.isEmpty) {
          _failPrepare('Нет viewerId у дочерних — используйте «Переслать и вступить»');
          state.finishAction(
            action.id,
            status: ActiveActionStatus.failed,
            message: 'Нет viewerId у дочерних',
          );
          return;
        }
        result = await MaxMotherService.inviteChildren(
          motherToken: m.apiToken!,
          links: prepared.manualUrls,
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          inviteUserIds: inviteIds,
          childTargets: childTargets,
          delayMs: delay,
          proxy: proxy,
          onProgress: trackProgress,
          cancel: action.cancelToken,
        );
        await _afterRun(result, mother.id, children: prepared.children);
      } else if (mode == _MotherMode.forwardOnly) {
        await state.ensureViewerId(mother);
        final mForward = state.accountById(mother.id)!;
        final forwardIds = <int>[];
        for (final child in prepared.children) {
          final id = await state.ensureViewerId(child);
          if (id != null) forwardIds.add(id);
        }
        if (forwardIds.isEmpty) {
          _failPrepare('Нет viewerId у дочерних — откройте их в MAX');
          state.finishAction(
            action.id,
            status: ActiveActionStatus.failed,
            message: 'Нет viewerId у дочерних',
          );
          return;
        }
        result = await MaxMotherService.forwardLinks(
          motherToken: mForward.apiToken!,
          links: prepared.manualUrls,
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          forwardUserIds: forwardIds,
          delayMs: delay,
          proxy: proxy,
          onProgress: trackProgress,
          cancel: action.cancelToken,
        );
        await _afterRun(result, mother.id, children: prepared.children);
      } else if (mode == _MotherMode.forwardAndJoin) {
        await state.ensureViewerId(mother);
        final mFj = state.accountById(mother.id)!;
        final targets = <Map<String, dynamic>>[];
        final tokenChildren = <MaxAccount>[];
        for (final child in prepared.children) {
          final id = await state.ensureViewerId(child);
          final fresh = state.accountById(child.id)!;
          if (id != null && fresh.hasApiSession) {
            tokenChildren.add(fresh);
            final childProxy = fresh.isolation.proxyServer?.trim();
            targets.add({
              'userId': id,
              'token': fresh.apiToken!,
              if (fresh.phone != null) 'phone': fresh.phone!,
              if ((childProxy != null && childProxy.isNotEmpty) ||
                  (proxy != null && proxy.trim().isNotEmpty))
                'proxy': (childProxy != null && childProxy.isNotEmpty) ? childProxy : proxy!.trim(),
            });
          }
        }
        if (targets.isEmpty) {
          _failPrepare('Нужны токен и viewerId у дочерних аккаунтов');
          state.finishAction(
            action.id,
            status: ActiveActionStatus.failed,
            message: 'Нет токена/viewerId у дочерних',
          );
          return;
        }
        result = await MaxMotherService.forwardAndJoin(
          motherToken: mFj.apiToken!,
          links: prepared.manualUrls,
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          childTargets: targets,
          delayMs: delay,
          proxy: proxy,
          onProgress: trackProgress,
          cancel: action.cancelToken,
        );
        await _afterRun(result, mother.id, children: tokenChildren);
      } else if (mode == _MotherMode.childrenJoinOnly) {
        final tokens = <String>[];
        final childProxies = <String?>[];
        final tokenChildren = <MaxAccount>[];
        for (final child in prepared.children) {
          await state.ensureViewerId(child);
          final fresh = state.accountById(child.id)!;
          if (fresh.hasApiSession) {
            tokenChildren.add(fresh);
            tokens.add(fresh.apiToken!);
            final p = fresh.isolation.proxyServer?.trim();
            childProxies.add((p != null && p.isNotEmpty) ? p : proxy);
          }
        }
        if (tokens.isEmpty) {
          _failPrepare('Нет токенов у дочерних аккаунтов');
          state.finishAction(
            action.id,
            status: ActiveActionStatus.failed,
            message: 'Нет токенов у дочерних',
          );
          return;
        }
        result = await MaxMotherService.childrenJoin(
          childTokens: tokens,
          links: prepared.manualUrls,
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          motherToken: state.accountById(mother.id)?.apiToken,
          delayMs: delay,
          proxy: proxy,
          childProxies: childProxies,
          onProgress: trackProgress,
          cancel: action.cancelToken,
        );
        await _afterRun(result, mother.id, children: tokenChildren);
      } else {
        await state.ensureViewerId(mother);
        final freshMother = state.accountById(mother.id)!;
        final inviteIds = <int>[];
        final forwardIds = <int>[];
        final childTokens = <String>[];
        final childTargets = <Map<String, dynamic>>[];
        final tokenChildren = <MaxAccount>[];
        for (final child in prepared.children) {
          final id = await state.ensureViewerId(child);
          final fresh = state.accountById(child.id)!;
          if (id != null) {
            inviteIds.add(id);
            forwardIds.add(id);
          }
          if (fresh.hasApiSession) {
            tokenChildren.add(fresh);
            childTokens.add(fresh.apiToken!);
            if (id != null) {
              final childProxy = fresh.isolation.proxyServer?.trim();
              childTargets.add({
                'userId': id,
                'token': fresh.apiToken!,
                if (fresh.phone != null) 'phone': fresh.phone!,
                if ((childProxy != null && childProxy.isNotEmpty) ||
                    (proxy != null && proxy.trim().isNotEmpty))
                  'proxy': (childProxy != null && childProxy.isNotEmpty) ? childProxy : proxy!.trim(),
              });
            }
          }
        }
        result = await MaxMotherService.motherDeploy(
          motherToken: freshMother.apiToken!,
          links: prepared.manualUrls,
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          inviteUserIds: inviteIds,
          forwardUserIds: forwardIds,
          childTokens: childTokens,
          childTargets: childTargets,
          delayMs: delay,
          inviteChildren: inviteIds.isNotEmpty,
          forwardChildren: forwardIds.isNotEmpty,
          childrenJoin: childTokens.isNotEmpty,
          proxy: proxy,
          onProgress: trackProgress,
          cancel: action.cancelToken,
        );
        await _afterRun(result, mother.id, children: tokenChildren.isNotEmpty ? tokenChildren : prepared.children);
      }

      if (action.cancelToken.isCancelled) {
        _log('⏹ Остановлено пользователем', level: 'warn');
        return;
      }

      if (result.ok) {
        _log('✓ ${result.message}');
      } else {
        _log('✗ ${result.message}', level: 'error');
      }
      _log('─── Детали (${result.results.length} шагов) ───');
      for (final row in result.results) {
        final ok = row['ok'] == true;
        final phase = row['phase'] ?? '?';
        final title = row['title'] ?? row['hash'] ?? row['chatId'] ?? '';
        final err = row['error'];
        final childId = row['childUserId'];
        final suffix = err != null ? ' → $err' : (childId != null ? ' → child $childId' : '');
        _log(
          '${ok ? "✓" : "✗"} [$phase] $title$suffix',
          level: ok ? 'info' : 'warn',
        );
      }
      for (final err in result.results.where((r) => r['ok'] != true).take(15)) {
        _log('  · ${err['phase'] ?? '?'} ${err['hash'] ?? ''}: ${err['error'] ?? '?'}', level: 'warn');
      }

      final webJoinUrls = prepared.urls;
      final shouldOpenWebConfirm = webJoinUrls.isNotEmpty &&
          prepared.children.isNotEmpty &&
          (result.forwarded > 0 ||
              mode == _MotherMode.childrenJoinOnly ||
              mode == _MotherMode.forwardOnly ||
              mode == _MotherMode.forwardAndJoin);
      if (shouldOpenWebConfirm) {
        await _confirmJoinLinksInChildBrowser(urls: webJoinUrls, children: prepared.children);
      }

      final shouldPostJoin = mode == _MotherMode.childrenJoinOnly ||
          mode == _MotherMode.forwardAndJoin ||
          mode == _MotherMode.full ||
          mode == _MotherMode.motherJoin;
      if (shouldPostJoin && !action.cancelToken.isCancelled) {
        final tokenChildren = <MaxAccount>[];
        if (mode == _MotherMode.motherJoin) {
          final freshMother = state.accountById(mother.id);
          if (freshMother != null && freshMother.hasApiSession) {
            tokenChildren.add(freshMother);
          }
        } else {
          for (final child in prepared.children) {
            final fresh = state.accountById(child.id);
            if (fresh != null && fresh.hasApiSession) tokenChildren.add(fresh);
          }
        }
        await _runPostJoinWrites(
          tokenChildren: tokenChildren,
          joinResults: result.results,
          cancel: action.cancelToken,
        );
      }

      state.finishAction(
        action.id,
        status: result.ok ? ActiveActionStatus.completed : ActiveActionStatus.failed,
        message: result.message,
      );
    } catch (e) {
      _log('✗ $e', level: 'error');
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.failed,
        message: e.toString(),
      );
    } finally {
      if (action.isActive) {
        state.finishAction(
          action.id,
          status: action.cancelToken.isCancelled
              ? ActiveActionStatus.cancelled
              : ActiveActionStatus.completed,
        );
      }
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _run() => _runMode(_MotherMode.full);

  Widget _buildSpeedFields(BuildContext context, AppState state) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Скорость', style: theme.textTheme.titleSmall?.copyWith(fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              'Пауза между шагами матки: вступление в группы, приглашение дочерних, пересылка.',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    enabled: !_running,
                    controller: _delayController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: 'Пауза между приглашениями (сек)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onEditingComplete: () => _persistRateSettings(state),
                    onSubmitted: (_) => _persistRateSettings(state),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _running ? null : () => _persistRateSettings(state),
                child: const Text('Сохранить', style: TextStyle(fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMembershipCard(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    final trackedIds = <String>{
      if (_motherId != null) _motherId!,
      ..._childIds,
    };
    final records = state.storage.accountGroupMemberships.values
        .where((m) => trackedIds.contains(m.accountId))
        .toList();
    final byAccount = <String, int>{};
    for (final m in records) {
      byAccount[m.accountId] = (byAccount[m.accountId] ?? 0) + 1;
    }
    final selected = _selectedGroupIds;
    final verify = _lastVerify;

    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Учёт вступлений',
              style: theme.textTheme.titleSmall?.copyWith(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              records.isEmpty
                  ? 'Пока пусто — после вступления/приглашения группы сохранятся здесь. '
                      '«Проверить вступления» сверит матку и дочерних с выбранными каналами.'
                  : 'В учёте: ${records.length} записей · ${byAccount.length} акк. · '
                      'проверка по ${_selectedGroupIds.length} выбранным группам.',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
            ),
            if (byAccount.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final entry in byAccount.entries.take(8))
                Builder(
                  builder: (_) {
                    final account = state.accountById(entry.key);
                    final inSelected = selected.isEmpty
                        ? entry.value
                        : state
                            .membershipsFor(entry.key)
                            .where((m) => selected.contains(m.chatId))
                            .length;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '· ${account?.profileDisplayName ?? entry.key}: '
                        '${selected.isEmpty ? entry.value : '$inSelected/${selected.length}'} групп',
                        style: const TextStyle(fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
            ],
            if (verify != null) ...[
              const SizedBox(height: 8),
              Text(
                verify.allOk
                    ? 'Последняя проверка: всё на месте (${verify.checked} акк.)'
                    : 'Последняя проверка: нет в группах — ${verify.missingTotal} пропусков',
                style: TextStyle(
                  fontSize: 11,
                  color: verify.allOk ? const Color(0xFFA5D6A7) : Colors.orangeAccent,
                ),
              ),
              for (final row in verify.rows.where((r) => !r.ok).take(6))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    row.error != null
                        ? '✗ ${row.accountLabel}: ${row.error}'
                        : '✗ ${row.accountLabel}: нет в ${row.missingChatIds.length}',
                    style: const TextStyle(fontSize: 10, color: Colors.orangeAccent),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoverJoinCard(BuildContext context, {required bool motherHasToken}) {
    final theme = Theme.of(context);
    final known = StorageService.instance.seenDiscoverCount;
    final inBase = StorageService.instance.channelCatalogEntries.length;

    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.travel_explore, size: 16),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Поиск каналов',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Назначения и вступление дочек — вкладка «Раздача» '
              '(все max.ru/join и кто уже вступил). '
              'В базе: $inBase · известных: $known. '
              'Здесь — только каналы, куда матка уже вошла сама, ручные ссылки и выход.',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _running
                  ? null
                  : () => context.read<AppState>().setNavPage(AppNavPage.assign),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Открыть «Раздача»', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMassInviteCard(BuildContext context, AppState state) {
    final plan = _massPlan ?? _computeMassPlan(state);
    final theme = Theme.of(context);
    final childCount = state.accounts.where((a) => !state.isMotherAccount(a.id)).length;
    final readyMothers = state.motherClusters.where((c) {
      final id = c.motherAccountId;
      if (id == null) return false;
      final m = state.accountById(id);
      return m != null && m.hasApiSession;
    }).length;

    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_motion, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Автонабор аккаунтов (≤${MotherInvitePlanner.defaultInvitesPerMother}/матка)',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Маток с токеном: $readyMothers · Аккаунтов: $childCount · '
              'Ёмкость: ${readyMothers * MotherInvitePlanner.defaultInvitesPerMother}',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
            ),
            const SizedBox(height: 4),
            Text(
              plan.summaryLine,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 10,
                color: plan.ok ? Colors.lightGreenAccent : Colors.orangeAccent,
              ),
            ),
            if (plan.motherSummaries.isNotEmpty) ...[
              const SizedBox(height: 6),
              ...plan.motherSummaries.take(6).map(
                    (s) => Text(
                      '· ${s.clusterName}: ${s.accountCount} акк → ${s.groupCount} групп',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                    ),
                  ),
              if (plan.motherSummaries.length > 6)
                Text(
                  '· …ещё ${plan.motherSummaries.length - 6}',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: _running || _massLoading ? null : _loadAllMotherGroups,
                  icon: _massLoading && !_running
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download, size: 16),
                  label: const Text('Загрузить маток', style: TextStyle(fontSize: 11)),
                ),
                OutlinedButton.icon(
                  onPressed: _running || _massLoading
                      ? null
                      : () {
                          setState(() => _massPlan = _computeMassPlan(state));
                          _log(_massPlan!.summaryLine);
                        },
                  icon: const Icon(Icons.calculate, size: 16),
                  label: const Text('Пересчитать', style: TextStyle(fontSize: 11)),
                ),
                FilledButton.icon(
                  onPressed: _running || _massLoading || !_cliReady
                      ? null
                      : _runMassProportionalInvite,
                  icon: _running
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.group_add, size: 16),
                  label: Text(
                    _running ? 'Набор…' : 'Распределить и пригласить',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Берутся все аккаунты, которые не назначены матками. Делятся по маткам '
              '(макс. 100), затем равномерно по группам каждой матки.',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 9, color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final accounts = state.accounts;
    final clusters = state.motherClusters;

    _hydrateRateSettings(state.rateSettings);
    _ensureActiveCluster(state);

    final occupiedElsewhere = state.accountMap.occupiedAccountIds(exceptClusterId: _activeClusterId);
    // All accounts can be mother or child — occupied ones are moved here on select.
    final motherChoices = accounts.toList();
    final childChoices = accounts.where((a) => a.id != _motherId).toList();

    String? otherClusterLabel(String accountId) {
      if (!occupiedElsewhere.contains(accountId)) return null;
      return state.clusterContainingAccount(accountId)?.name;
    }

    if (_motherId != null && !accounts.any((a) => a.id == _motherId)) {
      _motherId = null;
    }

    if (_motherId != _groupsLoadedForMotherId) {
      final motherId = _motherId;
      _groupsLoadedForMotherId = motherId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _loadStoredGroups(motherId));
      });
    }

    final mother = _mother(state);
    final manualHashCount = JoinLinkParser.parseHashes(_linksController.text).length;
    final selectedGroupLinkCount = _motherGroups
        .where((g) => _selectedGroupIds.contains(g.chatId) && g.hasInviteLink)
        .length;
    final targetCount = manualHashCount + selectedGroupLinkCount;
    final motherHasToken = mother?.hasApiSession == true;
    final activeCluster = state.accountMap.clusterById(_activeClusterId ?? '');

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        if (!_cliReady)
          Card(
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Text('Нужен Node.js + npm install в tools/max_auth', style: TextStyle(fontSize: 11)),
            ),
          ),
        if (!_cliReady) const SizedBox(height: 8),
        Text(
          'Связи матка ↔ дочерние задаются заранее — каналы для этого не нужны. '
          'Отметьте аккаунт: он переедет к этой матке, даже если был у другой.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'Матки (${clusters.length})',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Переименовать',
              onPressed: _running || activeCluster == null ? null : _renameActiveCluster,
              icon: const Icon(Icons.edit, size: 18),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: 'Удалить матку',
              onPressed: _running || activeCluster == null ? null : _deleteActiveCluster,
              icon: const Icon(Icons.delete_outline, size: 18),
              visualDensity: VisualDensity.compact,
            ),
            FilledButton.tonalIcon(
              onPressed: _running ? null : _addCluster,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Добавить', style: TextStyle(fontSize: 11)),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (clusters.isEmpty)
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Пока нет маток. Создайте первую — затем привяжите аккаунт и дочерние.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _running ? null : _addCluster,
                    icon: const Icon(Icons.hive, size: 18),
                    label: const Text('Создать матку'),
                  ),
                ],
              ),
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final cluster in clusters)
                ChoiceChip(
                  selected: cluster.id == _activeClusterId,
                  label: Text(
                    '${cluster.name} · ${cluster.childCount}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  avatar: Icon(
                    cluster.motherAccountId != null ? Icons.hive : Icons.hive_outlined,
                    size: 14,
                  ),
                  onSelected: _running
                      ? null
                      : (_) => _selectCluster(cluster),
                ),
            ],
          ),
        if (clusters.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildMassInviteCard(context, state),
          const SizedBox(height: 10),
          _buildSpeedFields(context, state),
        ],
        if (clusters.isEmpty) const SizedBox.shrink() else ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('mother-account-$_activeClusterId'),
          isExpanded: true,
          initialValue: motherChoices.any((a) => a.id == _motherId) ? _motherId : null,
          decoration: InputDecoration(
            labelText: 'Аккаунт-матка${activeCluster != null ? ' · ${activeCluster.name}' : ''}',
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            helperText: 'Можно выбрать аккаунт с другой матки — он перепривяжется',
          ),
          items: [
            for (final a in motherChoices)
              DropdownMenuItem(
                value: a.id,
                child: Text(
                  () {
                    final other = otherClusterLabel(a.id);
                    final mark = a.hasApiSession ? '✓' : '!';
                    if (other == null || a.id == _motherId) {
                      return '$mark  ${a.label}';
                    }
                    return '$mark  ${a.label} · сейчас: $other';
                  }(),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
          ],
          onChanged: _running
              ? null
              : (v) {
                  setState(() {
                    _motherId = v;
                    _childIds.remove(v);
                    _groupsLoadedForMotherId = null;
                  });
                  _syncMapRelations();
                },
        ),
        if (mother != null && !motherHasToken) ...[
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '«${mother.label}» без API-токена. Откройте его в MAX слева, затем:',
                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onTertiaryContainer),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: _running || _capturingToken ? null : _captureToken,
                    child: Text(_capturingToken ? 'Читаем…' : 'Взять токен из MAX'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'Доп. ссылка ($manualHashCount)',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ),
            TextButton.icon(
              onPressed: _running ? null : _pasteClipboard,
              icon: const Icon(Icons.paste, size: 16),
              label: const Text('Вставить'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        TextField(
          controller: _linksController,
          enabled: !_running,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
            hintText: 'https://max.ru/join/… — ещё один канал по своей ссылке',
            helperText: 'Необязательно: добавится к выбранным каналам матки',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        _buildDiscoverJoinCard(context, motherHasToken: motherHasToken),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'Каналы матки (${_selectedGroupIds.length}/${_motherGroups.length})',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ),
            if (_motherGroups.isNotEmpty) ...[
              TextButton(
                onPressed: _running || _loadingGroups
                    ? null
                    : () {
                        setState(() {
                          _selectedGroupIds
                            ..clear()
                            ..addAll(_motherGroups.map((g) => g.chatId));
                        });
                      },
                child: const Text('Все', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: _running || _loadingGroups
                    ? null
                    : () {
                        setState(() => _selectedGroupIds.clear());
                      },
                child: const Text('Снять', style: TextStyle(fontSize: 11)),
              ),
            ],
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              onPressed: _running || _loadingGroups || !motherHasToken
                  ? null
                  : () => _refreshMotherGroups(),
              icon: _loadingGroups
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: const Text('Загрузить каналы', style: TextStyle(fontSize: 11)),
            ),
            OutlinedButton.icon(
              onPressed: _running || _loadingGroups || !motherHasToken || _selectedGroupIds.isEmpty
                  ? null
                  : _scanSelectedGroupLinks,
              icon: const Icon(Icons.link, size: 16),
              label: const Text('Взять ссылки из профиля', style: TextStyle(fontSize: 11)),
            ),
            OutlinedButton.icon(
              onPressed: _running ||
                      _loadingGroups ||
                      !_cliReady ||
                      !motherHasToken ||
                      _selectedGroupIds.isEmpty
                  ? null
                  : _leaveSelectedGroups,
              icon: const Icon(Icons.logout, size: 16),
              label: Text(
                'Выйти (${_selectedGroupIds.length})',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _running ||
                      _verifyingMembership ||
                      !_cliReady ||
                      _selectedGroupIds.isEmpty ||
                      (_childIds.isEmpty && !motherHasToken)
                  ? null
                  : _verifyMemberships,
              icon: _verifyingMembership
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined, size: 16),
              label: const Text('Проверить вступления', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildMembershipCard(context, state),
        const SizedBox(height: 6),
        if (_motherGroups.isEmpty)
          Text(
            motherHasToken
                ? 'Нажмите «Загрузить каналы» — появятся группы, куда матка уже вступила'
                : 'Сначала возьмите токен матки',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
          )
        else
          SizedBox(
            height: 132,
            child: ListView(
              children: [
                for (final group in _motherGroups)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(group.title, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      group.deliveryLabel,
                      style: TextStyle(
                        fontSize: 10,
                        color: group.hasInviteLink ? Colors.lightGreenAccent : Colors.blueAccent,
                      ),
                    ),
                    value: _selectedGroupIds.contains(group.chatId),
                    onChanged: _running
                        ? null
                        : (v) {
                            setState(() {
                              if (v == true) {
                                _selectedGroupIds.add(group.chatId);
                              } else {
                                _selectedGroupIds.remove(group.chatId);
                              }
                            });
                          },
                  ),
              ],
            ),
          ),
        if (targetCount > 0 || manualHashCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              manualHashCount > 0
                  ? 'К обработке: $selectedGroupLinkCount из каналов + $manualHashCount доп. ссылок'
                  : 'К обработке: $targetCount ссылок из каналов матки',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10, color: Colors.lightBlueAccent),
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'Дочерние (${_childIds.length})',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ),
            if (childChoices.length > 1) ...[
              TextButton(
                onPressed: _running
                    ? null
                    : () {
                        setState(() {
                          // Everyone not tied to another cluster (channels not required).
                          _childIds
                            ..clear()
                            ..addAll(
                              childChoices
                                  .where((a) => !occupiedElsewhere.contains(a.id))
                                  .map((a) => a.id),
                            );
                        });
                        _syncMapRelations();
                      },
                child: const Text('Все свободные', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: _running
                    ? null
                    : () {
                        setState(() => _childIds.clear());
                        _syncMapRelations();
                      },
                child: const Text('Снять', style: TextStyle(fontSize: 11)),
              ),
            ],
          ],
        ),
        if (childChoices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Добавьте ещё аккаунты',
              style: TextStyle(fontSize: 11),
              textAlign: TextAlign.center,
            ),
          )
        else
          for (final a in childChoices)
            Builder(
              builder: (context) {
                final other = otherClusterLabel(a.id);
                final tokenLine = a.hasApiSession
                    ? (a.viewerId != null ? 'id ${a.viewerId}' : 'токен ✓')
                    : 'нет токена — не сможет вступить';
                final subtitle = other != null && !_childIds.contains(a.id)
                    ? '$tokenLine · сейчас: $other (отметьте — перенести)'
                    : tokenLine;
                return CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(a.label, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 10,
                      color: a.hasApiSession
                          ? (other != null && !_childIds.contains(a.id) ? Colors.amberAccent : null)
                          : Colors.orangeAccent,
                    ),
                  ),
                  secondary: !a.hasApiSession
                      ? TextButton(
                          onPressed: _running || _capturingToken ? null : () => _captureChildToken(a),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Токен', style: TextStyle(fontSize: 10)),
                        )
                      : null,
                  value: _childIds.contains(a.id),
                  onChanged: _running
                      ? null
                      : (v) {
                          setState(() {
                            if (v == true) {
                              _childIds.add(a.id);
                            } else {
                              _childIds.remove(a.id);
                            }
                          });
                          _syncMapRelations();
                        },
                );
              },
            ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Привязка не требует каналов. Каналы нужны только для вступления/пересылки.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
          ),
        ),
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Builder(
              builder: (context) {
                final withTemplate = _childIds.where((id) {
                  final t = state.joinTemplateForAccount(id);
                  return t != null && t.isActive;
                }).length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Письмо после вступления',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      withTemplate > 0
                          ? 'У $withTemplate из ${_childIds.length} дочерних назначен шаблон. '
                              'После «Дочерние по ссылкам» / «Переслать и вступить» / «Всё сразу» они напишут в чат.'
                          : 'Тексты настраиваются во вкладке «Шаблоны». '
                              'Назначьте шаблон дочерним — иначе после вступления писать некому.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: _running
                              ? null
                              : () => context.read<AppState>().setNavPage(AppNavPage.templates),
                          icon: const Icon(Icons.description_outlined, size: 16),
                          label: const Text('Шаблоны', style: TextStyle(fontSize: 11)),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: _running ||
                                  _childIds.isEmpty ||
                                  _selectedGroupIds.isEmpty ||
                                  withTemplate == 0
                              ? null
                              : _writeNowToSelectedChats,
                          icon: const Icon(Icons.send, size: 16),
                          label: const Text('Написать сейчас', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        if (_childIds.isEmpty && childChoices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Отметьте дочерний аккаунт выше — без этого кнопки «Переслать…» неактивны',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.orangeAccent,
                    fontSize: 10,
                  ),
            ),
          ),
        const SizedBox(height: 12),
        Text('Отдельные шаги', style: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: _running || !_cliReady || !motherHasToken || _childIds.isEmpty
                  ? null
                  : () => _runMode(_MotherMode.forwardAndJoin),
              child: const Text('Переслать и вступить', style: TextStyle(fontSize: 11)),
            ),
            OutlinedButton(
              onPressed: _running || !_cliReady || !motherHasToken || _childIds.isEmpty
                  ? null
                  : () => _runMode(_MotherMode.forwardOnly),
              child: const Text('Только переслать', style: TextStyle(fontSize: 11)),
            ),
            OutlinedButton(
              onPressed: _running || !_cliReady || !motherHasToken
                  ? null
                  : () => _runMode(_MotherMode.inviteOnly),
              child: const Text('По ID (админ)', style: TextStyle(fontSize: 11)),
            ),
            OutlinedButton(
              onPressed: _running || !_cliReady || _childIds.isEmpty
                  ? null
                  : () => _runMode(_MotherMode.childrenJoinOnly),
              child: const Text('Дочерние по ссылкам', style: TextStyle(fontSize: 11)),
            ),
            OutlinedButton(
              onPressed: _running || !_cliReady || !motherHasToken
                  ? null
                  : () => _runMode(_MotherMode.motherJoin),
              child: const Text('Вступить + шаблон', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _running || !_cliReady || !motherHasToken || _childIds.isEmpty ? null : _run,
          icon: _running
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.rocket_launch, size: 18),
          label: Text(_running ? 'Выполняется…' : 'Всё сразу ($targetCount)'),
        ),
        if (_childIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Для каждого канала: проверка «уже в канале» → по ID → пересылка ссылки → вступление дочернего',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.orangeAccent,
                    fontSize: 10,
                  ),
            ),
          ),
        ],
      ],
    );
  }
}
