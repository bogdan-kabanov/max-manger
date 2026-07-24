import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/account_group_membership.dart';
import '../models/account_map_state.dart';
import '../models/account_isolation.dart';
import '../models/active_action.dart';
import '../models/ai_chat_config.dart';
import '../models/app_nav_page.dart';
import '../models/automation_rule.dart';
import '../models/channel_funnel.dart';
import '../models/emulator_profile.dart';
import '../models/join_message_template.dart';
import '../models/macro_scenario.dart';
import '../models/macro_step.dart';
import '../models/matka_template_binding.dart';
import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import '../models/mother_group_channel.dart';
import '../models/pipeline_journal_event.dart';
import '../models/profile_template.dart';
import '../models/rate_settings.dart';
import '../models/template_send_scope.dart';
import '../models/template_sent_record.dart';
import '../services/browser_session_manager.dart';
import '../services/ai_chat_service.dart';
import '../services/emulator_macro_runner.dart';
import '../services/max_auth_service.dart';
import '../services/max_ws_service.dart';
import '../models/map_workflow.dart';
import '../services/broadcast_workflow_runner.dart';
import '../services/channel_funnel_runner.dart';
import '../services/child_post_join_runner.dart';
import '../services/max_mother_service.dart';
import '../services/pipeline_group_planner.dart';
import '../utils/join_link_parser.dart';
import '../services/scenario_scheduler.dart';
import '../services/storage_service.dart';

enum EmulatorMirrorMode { control, record, view }

extension EmulatorMirrorModeX on EmulatorMirrorMode {
  bool get canInteract => this != EmulatorMirrorMode.view;
}

class AppState extends ChangeNotifier {
  AppState(this.browser) {
    _scheduler = ScenarioScheduler();
    _startDailyTemplateTicker();
  }

  final BrowserSessionManager browser;
  final MaxWsService maxWs = MaxWsService();
  final StorageService storage = StorageService.instance;
  late final ScenarioScheduler _scheduler;
  final BroadcastWorkflowRunner _broadcastRunner = BroadcastWorkflowRunner();
  final ChannelFunnelRunner _funnelRunner = ChannelFunnelRunner();
  Timer? _dailyTemplateTimer;
  final Set<String> _firedDailyKeys = {};
  final Map<String, DateTime> _lastTemplateRepeatAt = {};
  bool funnelRunning = false;
  final List<ActiveAction> _activeActions = [];
  int _actionSeq = 0;
  Timer? _actionWaitTicker;

  List<ActiveAction> get activeActions => List.unmodifiable(_activeActions);
  int get runningActionsCount =>
      _activeActions.where((a) => a.isActive).length;

  ActiveAction? actionById(String id) => _actionById(id);

  ActiveAction beginAction({
    required ActiveActionKind kind,
    required String title,
    String? subtitle,
  }) {
    _actionSeq += 1;
    final action = ActiveAction(
      id: 'act-${DateTime.now().millisecondsSinceEpoch}-$_actionSeq',
      kind: kind,
      title: title,
      subtitle: subtitle,
    );
    action.appendLog('Запущено');
    _activeActions.insert(0, action);
    notifyListeners();
    return action;
  }

  void updateActionProgress(
    String id, {
    String? message,
    int? done,
    int? total,
    String level = 'info',
    bool appendLog = true,
  }) {
    final action = _actionById(id);
    if (action == null || !action.isActive) return;
    if (message != null) {
      action.progressMessage = message;
      if (appendLog) action.appendLog(message, level: level);
      _syncWaitFromMessage(action, message);
    }
    if (done != null) action.done = done;
    if (total != null) action.total = total;
    notifyListeners();
  }

  void finishAction(
    String id, {
    ActiveActionStatus? status,
    String? message,
  }) {
    final action = _actionById(id);
    if (action == null) return;
    if (!action.isActive && status == null) return;
    final resolved = status ??
        (action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed);
    action.status = resolved;
    action.finishedAt = DateTime.now();
    action.clearWait();
    if (message != null && message.isNotEmpty) {
      action.progressMessage = message;
      action.appendLog(
        message,
        level: resolved == ActiveActionStatus.failed
            ? 'error'
            : resolved == ActiveActionStatus.cancelled
                ? 'warn'
                : 'info',
      );
    } else if (resolved == ActiveActionStatus.cancelled &&
        action.progressMessage.isEmpty) {
      action.progressMessage = 'Остановлено';
      action.appendLog('Остановлено', level: 'warn');
    } else if (resolved == ActiveActionStatus.completed &&
        (action.logs.isEmpty ||
            !action.logs.last.message.toLowerCase().contains('готов'))) {
      action.appendLog('Готово');
    }
    _stopWaitTickerIfIdle();
    notifyListeners();
  }

  void cancelAction(String id) {
    final action = _actionById(id);
    if (action == null || !action.isActive) return;
    action.status = ActiveActionStatus.cancelling;
    action.progressMessage = 'Остановка…';
    action.clearWait();
    action.appendLog('Остановка…', level: 'warn');
    action.cancelToken.cancel();
    _stopWaitTickerIfIdle();
    notifyListeners();
    browser.logMessage('[Действия] Остановка: ${action.title}', level: 'warn');
  }

  void cancelAllActions() {
    final active = _activeActions.where((a) => a.isActive).toList();
    for (final action in active) {
      action.status = ActiveActionStatus.cancelling;
      action.progressMessage = 'Остановка…';
      action.clearWait();
      action.appendLog('Остановка…', level: 'warn');
      action.cancelToken.cancel();
    }
    if (active.isNotEmpty) {
      _stopWaitTickerIfIdle();
      notifyListeners();
      browser.logMessage(
        '[Действия] Остановка всех (${active.length})',
        level: 'warn',
      );
    }
  }

  void clearFinishedActions() {
    final before = _activeActions.length;
    _activeActions.removeWhere((a) => !a.isActive);
    if (_activeActions.length != before) notifyListeners();
  }

  ActiveAction? _actionById(String id) {
    for (final a in _activeActions) {
      if (a.id == id) return a;
    }
    return null;
  }

  static final _pauseMsRe = RegExp(r'(\d+)\s*мс', caseSensitive: false);
  static final _leftSecRe = RegExp(r'осталось\s+(\d+)\s*с', caseSensitive: false);

  void _syncWaitFromMessage(ActiveAction action, String message) {
    final lower = message.toLowerCase();
    final left = _leftSecRe.firstMatch(lower);
    if (left != null) {
      final sec = int.tryParse(left.group(1)!);
      if (sec != null && sec >= 0) {
        action.waitUntil = DateTime.now().add(Duration(seconds: sec));
        action.waitLabel ??= message;
        _ensureWaitTicker();
        return;
      }
    }

    final isPause = lower.contains('пауза') || lower.contains('ожидание');
    if (isPause) {
      final msMatch = _pauseMsRe.firstMatch(message);
      if (msMatch != null) {
        final ms = int.tryParse(msMatch.group(1)!);
        if (ms != null && ms > 0) {
          // Avoid restarting the same announced pause on duplicate log lines.
          if (action.isWaiting && action.waitLabel == message) return;
          action.beginWait(Duration(milliseconds: ms), label: message);
          _ensureWaitTicker();
          return;
        }
      }
    }

    if (action.waitUntil != null) {
      action.clearWait();
      _stopWaitTickerIfIdle();
    }
  }

  void _ensureWaitTicker() {
    if (_actionWaitTicker != null) return;
    _actionWaitTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      var anyWaiting = false;
      for (final action in _activeActions) {
        if (action.waitUntil == null) continue;
        if (!action.isWaiting) {
          action.clearWait();
          continue;
        }
        anyWaiting = true;
      }
      if (!anyWaiting) {
        _actionWaitTicker?.cancel();
        _actionWaitTicker = null;
      }
      notifyListeners();
    });
  }

  void _stopWaitTickerIfIdle() {
    final anyWaiting = _activeActions.any((a) => a.isWaiting);
    if (!anyWaiting) {
      _actionWaitTicker?.cancel();
      _actionWaitTicker = null;
    }
  }

  MaxAccount? selectedAccount;
  String? selectedWorkflowNodeId;
  AppNavPage navPage = AppNavPage.profiles;
  bool automationEnabled = true;
  MacroScenario? editingScenario;
  bool emulatorPanelVisible = true;
  bool emulatorFocusMode = false;
  bool emulatorNativeClickMode = true;
  bool emulatorClickerVisible = false;
  double emulatorWebFraction = 0.32;
  EmulatorMirrorMode emulatorMirrorMode = EmulatorMirrorMode.control;

  bool browserDrawerOpen = false;
  AccountMapActivity? mapActivity;
  Timer? _mapActivityTimer;

  AccountMapState get accountMap => storage.accountMap;
  RateSettings get rateSettings => storage.rateSettings;
  List<MotherCluster> get motherClusters => accountMap.motherClusters;
  String? get motherAccountId => accountMap.motherAccountId;
  Set<String> get childAccountIds => accountMap.childAccountIds;
  bool isMotherAccount(String accountId) => accountMap.isMotherAccount(accountId);
  bool isChildAccount(String accountId) => accountMap.isChildAccount(accountId);
  List<MapWorkflowNode> get workflowNodes => accountMap.workflowNodes;
  List<WorkflowMapEdge> get workflowEdges => accountMap.workflowEdges;
  List<ChannelFunnel> get channelFunnels => storage.channelFunnels;
  List<JoinMessageTemplate> get joinMessageTemplates => storage.joinMessageTemplates;
  Map<String, String> get joinTemplateByAccountId =>
      Map.unmodifiable(storage.joinTemplateByAccountId);
  List<ProfileTemplate> get profileTemplates => storage.profileTemplates;
  Map<String, String> get profileTemplateByAccountId =>
      Map.unmodifiable(storage.profileTemplateByAccountId);

  AccountChannelPolicy channelPolicyFor(String accountId) =>
      storage.channelPolicyFor(accountId);

  JoinMessageTemplate? joinTemplateForAccount(String accountId) =>
      storage.joinTemplateForAccount(accountId);

  ProfileTemplate? profileTemplateForAccount(String accountId) =>
      storage.profileTemplateForAccount(accountId);

  JoinMessageTemplate? joinMessageTemplateById(String? id) {
    if (id == null) return null;
    for (final t in joinMessageTemplates) {
      if (t.id == id) return t;
    }
    return null;
  }

  ProfileTemplate? profileTemplateById(String? id) {
    if (id == null) return null;
    for (final t in profileTemplates) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _persistJoinMessageTemplates(List<JoinMessageTemplate> templates) async {
    await storage.saveJoinMessageTemplates(templates);
    notifyListeners();
  }

  Future<void> _persistJoinTemplateAssignments(Map<String, String> assignments) async {
    await storage.saveJoinTemplateAssignments(assignments);
    notifyListeners();
  }

  Future<JoinMessageTemplate> addJoinMessageTemplate({String? name}) async {
    final index = joinMessageTemplates.length + 1;
    final template = JoinMessageTemplate.create(name: name ?? 'Шаблон $index');
    await _persistJoinMessageTemplates([...joinMessageTemplates, template]);
    return template;
  }

  Future<void> updateJoinMessageTemplate(JoinMessageTemplate template) async {
    final list =
        joinMessageTemplates.map((t) => t.id == template.id ? template : t).toList();
    await _persistJoinMessageTemplates(list);
  }

  Future<void> removeJoinMessageTemplate(String templateId) async {
    await _persistJoinMessageTemplates(
      joinMessageTemplates.where((t) => t.id != templateId).toList(),
    );
    final assign = Map<String, String>.from(storage.joinTemplateByAccountId)
      ..removeWhere((_, id) => id == templateId);
    await _persistJoinTemplateAssignments(assign);
    final bindings =
        matkaTemplateBindings.where((b) => b.templateId != templateId).toList();
    if (bindings.length != matkaTemplateBindings.length) {
      await _persistMatkaTemplateBindings(bindings);
    }
    await storage.clearTemplateSentHistory(templateId: templateId);
  }

  int countTemplateSentHistory(String templateId) =>
      storage.countTemplateSent(templateId: templateId);

  Future<void> clearTemplateSentHistory(String templateId) async {
    await storage.clearTemplateSentHistory(templateId: templateId);
    notifyListeners();
  }

  Future<String> deleteTemplateMessages({
    required MaxAccount account,
    required String templateId,
    required List<String> chatIds,
  }) async {
    if (!account.hasApiSession) return 'Нет токена';
    final items = <Map<String, dynamic>>[];
    for (final chatId in chatIds) {
      final rec = storage.templateSentRecord(
        accountId: account.id,
        chatId: chatId,
        templateId: templateId,
      );
      if (rec == null || rec.messageIds.isEmpty) continue;
      items.add({'chatId': chatId, 'messageIds': rec.messageIds});
    }
    if (items.isEmpty) {
      return 'Нет id сообщений для удаления';
    }

    final action = beginAction(
      kind: ActiveActionKind.postJoinMessage,
      title: 'Удаление сообщений',
      subtitle: '${items.length} чат(ов)',
    );
    try {
      final result = await MaxMotherService.deleteChatMessages(
        token: account.apiToken!,
        items: items,
        forMe: false,
        proxy: account.isolation.proxyServer,
        cancel: action.cancelToken,
        onProgress: (msg) {
          browser.logMessage(msg);
          updateActionProgress(action.id, message: msg);
        },
      );
      final okChats = <String>[
        for (final row in result.results)
          if (row['ok'] == true) row['chatId']?.toString().trim() ?? '',
      ].where((e) => e.isNotEmpty).toList();
      if (okChats.isNotEmpty) {
        await storage.clearTemplateSentHistory(
          templateId: templateId,
          accountId: account.id,
          chatIds: okChats,
        );
        notifyListeners();
      }
      final message = result.ok
          ? 'Удалено id: ${result.deleted} · чатов: ${okChats.length}'
          : (result.message.isNotEmpty
              ? result.message
              : 'Ошибка удаления (удалено ${result.deleted})');
      finishAction(
        action.id,
        status: result.ok
            ? ActiveActionStatus.completed
            : ActiveActionStatus.failed,
        message: message,
      );
      return message;
    } catch (e) {
      finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
      return e.toString();
    }
  }

  Future<void> rememberTemplateSends({
    required MaxAccount child,
    required List<String> chatIds,
    String? templateId,
    Map<String, List<String>> messageIdsByChatId = const {},
    Map<String, String> titleByChatId = const {},
  }) async {
    final id = (templateId ?? storage.joinTemplateByAccountId[child.id] ?? '').trim();
    if (id.isEmpty || chatIds.isEmpty) return;
    await storage.markTemplateSentMany(
      accountId: child.id,
      chatIds: chatIds,
      templateId: id,
      messageIdsByChatId: messageIdsByChatId,
      titleByChatId: titleByChatId,
    );
    notifyListeners();
  }

  List<MatkaTemplateBinding> get matkaTemplateBindings =>
      List.unmodifiable(storage.matkaTemplateBindings);

  List<PipelineJournalEvent> get pipelineJournal =>
      List.unmodifiable(storage.pipelineJournal);

  List<MaxChannelCatalogEntry> get channelCatalog =>
      storage.channelCatalogEntries;

  Future<void> _persistMatkaTemplateBindings(List<MatkaTemplateBinding> bindings) async {
    await storage.saveMatkaTemplateBindings(bindings);
    notifyListeners();
  }

  Future<void> addPipelineJournal({
    required PipelineJournalKind kind,
    required String message,
    String? motherAccountId,
    String? childAccountId,
    String? chatId,
    String? detail,
  }) async {
    final event = PipelineJournalEvent.create(
      kind: kind,
      message: message,
      motherAccountId: motherAccountId,
      childAccountId: childAccountId,
      chatId: chatId,
      detail: detail,
    );
    await storage.appendPipelineJournal(event);
    browser.logMessage('[Конвейер] ${kind.label}: $message', level: kind == PipelineJournalKind.error || kind == PipelineJournalKind.warn ? 'warn' : 'info');
    notifyListeners();
  }

  Future<void> clearPipelineJournal() async {
    await storage.clearPipelineJournal();
    notifyListeners();
  }

  Future<void> assignCatalogGroupsToMother({
    required Iterable<String> chatIds,
    required String? motherAccountId,
  }) async {
    final ids = chatIds.toList();
    await storage.assignCatalogGroupsToMother(
      chatIds: ids,
      motherAccountId: motherAccountId,
    );
    final mother = motherAccountId != null ? accountById(motherAccountId) : null;
    await addPipelineJournal(
      kind: motherAccountId == null ? PipelineJournalKind.unassign : PipelineJournalKind.assign,
      message: motherAccountId == null
          ? 'Снято назначение с ${ids.length} групп'
          : 'Матке «${mother?.label ?? motherAccountId}» назначено ${ids.length} групп',
      motherAccountId: motherAccountId,
      detail: ids.take(20).join(', '),
    );
  }

  Future<void> mergeChannelCatalogEntries(List<MaxChannelCatalogEntry> entries) async {
    if (entries.isEmpty) return;
    await storage.mergeChannelCatalog(entries);
    notifyListeners();
  }

  Future<void> removeCatalogGroups(Iterable<String> chatIds) async {
    final ids = chatIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    await storage.saveChannelCatalog([
      for (final e in channelCatalog)
        if (!ids.contains(e.chatId)) e,
    ]);
    notifyListeners();
  }

  Future<void> clearChannelCatalog() async {
    await storage.saveChannelCatalog(const []);
    notifyListeners();
  }

  /// Paste `https://max.ru/join/…` links into catalog; optionally assign to a parent.
  Future<({int added, int alreadyKnown, int invalid})> importJoinLinks({
    required String rawText,
    String? motherAccountId,
  }) async {
    final motherId = motherAccountId?.trim();
    final mother = (motherId != null && motherId.isNotEmpty) ? accountById(motherId) : null;
    if (motherId != null && motherId.isNotEmpty && mother == null) {
      return (added: 0, alreadyKnown: 0, invalid: 0);
    }

    final hashes = JoinLinkParser.parseHashes(rawText);
    if (hashes.isEmpty) {
      return (added: 0, alreadyKnown: 0, invalid: 0);
    }

    final knownHashes = <String>{
      for (final e in channelCatalog)
        if (e.hasInviteLink) e.inviteHash!,
    };

    final incoming = <MaxChannelCatalogEntry>[];
    var alreadyKnown = 0;
    for (final hash in hashes) {
      if (!MotherGroupChannel.isValidInviteHash(hash)) continue;
      if (knownHashes.contains(hash)) {
        alreadyKnown += 1;
        continue;
      }
      knownHashes.add(hash);
      incoming.add(
        MaxChannelCatalogEntry(
          chatId: 'invite:$hash',
          title: 'ссылка ${hash.length > 14 ? '${hash.substring(0, 12)}…' : hash}',
          type: 'link',
          inviteHash: hash,
          source: 'paste',
          discoveredAt: DateTime.now(),
          assignedMotherAccountId: mother?.id,
        ),
      );
    }

    final reassignIds = mother == null
        ? const <String>[]
        : [
            for (final e in channelCatalog)
              if (e.hasInviteLink &&
                  hashes.contains(e.inviteHash) &&
                  e.assignedMotherAccountId != mother.id)
                e.chatId,
          ];

    if (incoming.isNotEmpty) {
      await storage.mergeChannelCatalog(incoming);
    }
    if (reassignIds.isNotEmpty) {
      await storage.assignCatalogGroupsToMother(
        chatIds: reassignIds,
        motherAccountId: mother!.id,
      );
    }

    final added = incoming.length;
    final moved = reassignIds.length;
    if (added > 0 || moved > 0) {
      await addPipelineJournal(
        kind: PipelineJournalKind.assign,
        message: mother == null
            ? 'Импорт ссылок в каталог: +$added'
                '${alreadyKnown > 0 ? ', уже были $alreadyKnown' : ''}'
            : 'Матке «${mother.label}» импорт ссылок: +$added'
                '${moved > 0 ? ', переназначено $moved' : ''}'
                '${alreadyKnown > 0 ? ', уже были $alreadyKnown' : ''}',
        motherAccountId: mother?.id,
      );
      notifyListeners();
    } else if (alreadyKnown > 0 && mother != null) {
      final freeKnown = [
        for (final e in channelCatalog)
          if (e.hasInviteLink && hashes.contains(e.inviteHash) && !e.isAssigned) e.chatId,
      ];
      if (freeKnown.isNotEmpty) {
        await assignCatalogGroupsToMother(
          chatIds: freeKnown,
          motherAccountId: mother.id,
        );
        return (
          added: freeKnown.length,
          alreadyKnown: alreadyKnown - freeKnown.length,
          invalid: 0,
        );
      }
      notifyListeners();
    } else if (added > 0 || alreadyKnown > 0) {
      notifyListeners();
    }

    return (
      added: added + moved,
      alreadyKnown: alreadyKnown,
      invalid: 0,
    );
  }

  /// Paste `https://max.ru/join/…` links into catalog and assign to [motherAccountId].
  Future<({int added, int alreadyKnown, int invalid})> importJoinLinksToMother({
    required String motherAccountId,
    required String rawText,
  }) =>
      importJoinLinks(rawText: rawText, motherAccountId: motherAccountId);

  Future<MatkaTemplateBinding?> addMatkaTemplateBinding({
    required String motherAccountId,
    required String templateId,
    MatkaTemplateTrigger trigger = MatkaTemplateTrigger.onJoin,
    int hour = 12,
    int minute = 0,
  }) async {
    if (joinMessageTemplateById(templateId) == null) return null;
    if (accountById(motherAccountId) == null) return null;
    final binding = MatkaTemplateBinding.create(
      motherAccountId: motherAccountId,
      templateId: templateId,
      trigger: trigger,
      hour: hour,
      minute: minute,
    );
    await _persistMatkaTemplateBindings([...matkaTemplateBindings, binding]);
    // Push onJoin templates onto cluster children so ChildPostJoinRunner sees them.
    if (trigger == MatkaTemplateTrigger.onJoin) {
      await _syncOnJoinBindingsToChildren(motherAccountId);
    }
    return binding;
  }

  Future<void> updateMatkaTemplateBinding(MatkaTemplateBinding binding) async {
    final list =
        matkaTemplateBindings.map((b) => b.id == binding.id ? binding : b).toList();
    await _persistMatkaTemplateBindings(list);
    await _syncOnJoinBindingsToChildren(binding.motherAccountId);
  }

  Future<void> removeMatkaTemplateBinding(String bindingId) async {
    final existing = matkaTemplateBindings.where((b) => b.id == bindingId).toList();
    if (existing.isEmpty) return;
    final motherId = existing.first.motherAccountId;
    await _persistMatkaTemplateBindings(
      matkaTemplateBindings.where((b) => b.id != bindingId).toList(),
    );
    await _syncOnJoinBindingsToChildren(motherId);
  }

  List<MatkaTemplateBinding> bindingsForMother(String motherAccountId) =>
      matkaTemplateBindings.where((b) => b.motherAccountId == motherAccountId).toList();

  /// First enabled onJoin template for matka → assign to workers (children or solo mother).
  Future<void> _syncOnJoinBindingsToChildren(String motherAccountId) async {
    final onJoin = bindingsForMother(motherAccountId)
        .where((b) => b.enabled && b.trigger == MatkaTemplateTrigger.onJoin)
        .toList();
    final cluster = motherClusters.cast<MotherCluster?>().firstWhere(
          (c) => c?.motherAccountId == motherAccountId,
          orElse: () => null,
        );
    if (cluster == null) return;
    final targets = cluster.childAccountIds.isNotEmpty
        ? cluster.childAccountIds
        : {
            if (cluster.motherAccountId != null) cluster.motherAccountId!,
          };
    if (targets.isEmpty) return;
    if (onJoin.isEmpty) {
      await clearJoinTemplateForAccounts(targets);
      return;
    }
    await applyJoinTemplateToAccounts(
      templateId: onJoin.first.templateId,
      accountIds: targets,
    );
  }

  PipelineLaunchPlan buildPipelineLaunchPlan({
    Set<String> alreadyJoinedChatIds = const {},
    String? onlyMotherId,
    Set<String>? onlyChatIds,
  }) {
    var catalog = channelCatalog;
    if (onlyMotherId != null && onlyMotherId.isNotEmpty) {
      catalog = [
        for (final e in catalog)
          if (e.assignedMotherAccountId == onlyMotherId) e,
      ];
    }
    if (onlyChatIds != null && onlyChatIds.isNotEmpty) {
      catalog = [
        for (final e in catalog)
          if (onlyChatIds.contains(e.chatId)) e,
      ];
    }
    var clusters = motherClusters;
    if (onlyMotherId != null && onlyMotherId.isNotEmpty) {
      clusters = [
        for (final c in clusters)
          if (c.motherAccountId == onlyMotherId) c,
      ];
    }
    return PipelineGroupPlanner.build(
      clusters: clusters,
      accounts: accounts,
      catalog: catalog,
      alreadyJoinedChatIds: alreadyJoinedChatIds,
    );
  }

  /// ChatIds already held by workers (дочки, либо соло-матка без дочек).
  Set<String> joinedChatIdsForPipeline() {
    final workerIds = <String>{};
    for (final c in motherClusters) {
      if (c.childAccountIds.isEmpty) {
        final mid = c.motherAccountId;
        if (mid != null) workerIds.add(mid);
      } else {
        workerIds.addAll(c.childAccountIds);
      }
    }
    final ids = <String>{};
    for (final m in storage.accountGroupMemberships.values) {
      if (workerIds.contains(m.accountId)) ids.add(m.chatId);
    }
    return ids;
  }

  /// Workers of [motherAccountId] who already joined [chatId] (дочки или соло-матка).
  List<MaxAccount> childrenJoinedChat({
    required String motherAccountId,
    required String chatId,
  }) {
    final cluster = motherClusters.cast<MotherCluster?>().firstWhere(
          (c) => c?.motherAccountId == motherAccountId,
          orElse: () => null,
        );
    if (cluster == null || chatId.trim().isEmpty) return const [];
    final workerIds = cluster.childAccountIds.isNotEmpty
        ? cluster.childAccountIds
        : [
            if (cluster.motherAccountId != null) cluster.motherAccountId!,
          ];
    final out = <MaxAccount>[];
    for (final id in workerIds) {
      if (!membershipChatIdsFor(id).contains(chatId)) continue;
      final a = accountById(id);
      if (a != null) out.add(a);
    }
    return out;
  }

  int childCountForMother(String motherAccountId) {
    for (final c in motherClusters) {
      if (c.motherAccountId == motherAccountId) return c.childAccountIds.length;
    }
    return 0;
  }

  /// After join, replace synthetic `invite:$hash` catalog ids with real chatIds.
  Future<void> remapCatalogFromJoinResults(List<Map<String, dynamic>> results) async {
    if (results.isEmpty) return;
    final byHash = <String, String>{}; // hash → chatId
    final titles = <String, String>{};
    for (final row in results) {
      if (row['ok'] != true) continue;
      final chatId = row['chatId']?.toString().trim() ?? '';
      final hash = row['hash']?.toString().trim() ?? '';
      if (chatId.isEmpty) continue;
      if (MotherGroupChannel.isValidInviteHash(hash)) {
        byHash[hash] = chatId;
      }
      final title = row['title']?.toString().trim() ?? '';
      if (title.isNotEmpty) titles[chatId] = title;
    }
    if (byHash.isEmpty) return;

    var changed = false;
    final next = <MaxChannelCatalogEntry>[];
    for (final e in channelCatalog) {
      final hash = e.inviteHash?.trim();
      final mapped = (hash != null && byHash.containsKey(hash)) ? byHash[hash]! : null;
      if (mapped == null || mapped == e.chatId) {
        next.add(e);
        continue;
      }
      changed = true;
      next.add(
        e.copyWith(
          chatId: mapped,
          title: titles[mapped]?.isNotEmpty == true
              ? titles[mapped]
              : (e.title.startsWith('ссылка ') && titles[mapped] != null
                  ? titles[mapped]
                  : e.title),
        ),
      );
    }
    if (!changed) return;
    // Dedupe if real chatId already existed.
    final merged = MaxChannelCatalogEntry.mergeLists(const [], next);
    await storage.saveChannelCatalog(merged);
    notifyListeners();
  }

  /// Children join assigned catalog groups by invite links (Раздача / Запуск).
  Future<({int joined, int slots, String message})> runPipelineChildrenJoinByLinks({
    String? onlyMotherId,
    Set<String>? onlyChatIds,
    void Function(String message)? onLog,
    ActionCancelToken? cancel,
    String? actionId,
  }) async {
    void track(String msg) {
      onLog?.call(msg);
      if (actionId != null) updateActionProgress(actionId, message: msg);
    }

    final plan = buildPipelineLaunchPlan(
      alreadyJoinedChatIds: joinedChatIdsForPipeline(),
      onlyMotherId: onlyMotherId,
      onlyChatIds: onlyChatIds,
    );
    if (!plan.ok) {
      return (joined: 0, slots: 0, message: plan.error ?? 'План пуст');
    }

    var doneSlots = 0;
    var joinedTotal = 0;
    final allResults = <Map<String, dynamic>>[];

    for (final slot in plan.slots) {
      if (cancel?.isCancelled == true) break;

      final withLink = slot.groups.where((g) => g.hasInviteLink).toList();
      if (withLink.isEmpty) {
        track('«${slot.child.label}»: нет ссылок — пропуск');
        doneSlots++;
        continue;
      }

      final soloWorker = slot.child.id == slot.mother.id;
      track(
        soloWorker
            ? '[${doneSlots + 1}/${plan.slots.length}] «${slot.child.label}» ← ${withLink.length} групп (сам)'
            : '[${doneSlots + 1}/${plan.slots.length}] «${slot.child.label}» ← ${withLink.length} групп '
                '(матка «${slot.mother.label}»)',
      );

      final groups = [
        for (final g in withLink) {'chatId': g.chatId, 'hash': g.inviteHash},
      ];
      final links = [
        for (final g in withLink)
          if (g.inviteUrl != null) g.inviteUrl!,
      ];
      final childProxy = slot.child.isolation.proxyServer?.trim();
      final childProxyOrNull =
          (childProxy != null && childProxy.isNotEmpty) ? childProxy : null;

      final result = await MaxMotherService.childrenJoin(
        childTokens: [slot.child.apiToken!],
        links: links,
        groups: groups,
        delayMs: rateSettings.motherJoinDelayMs,
        proxy: childProxyOrNull,
        childProxies: [childProxyOrNull],
        onProgress: track,
        cancel: cancel,
      );

      final okRows = result.results
          .where((r) => r['ok'] == true && r['phase'] == 'child_join')
          .length;
      joinedTotal += result.joined > 0 ? result.joined : okRows;
      allResults.addAll(result.results);

      track(
        result.ok
            ? '«${slot.child.label}»: ${result.message}'
            : '✗ «${slot.child.label}»: ${result.message}',
      );

      await recordMembershipsFromJoinResults(
        motherAccountId: null,
        children: [slot.child],
        results: result.results,
        titleByChatId: {for (final g in withLink) g.chatId: g.title},
      );
      await remapCatalogFromJoinResults(result.results);
      await addPipelineJournal(
        kind: PipelineJournalKind.joinLink,
        message: result.joined > 0
            ? '«${slot.child.label}»: вступило ${result.joined}/${withLink.length}'
            : '«${slot.child.label}»: вступило 0/${withLink.length} — ${result.message}',
        motherAccountId: slot.mother.id,
        childAccountId: slot.child.id,
      );

      final template = joinTemplateForAccount(slot.child.id);
      if (template != null && template.isActive && result.joined > 0) {
        track('Письмо после входа: «${template.name}»');
        final channelLinks = await ensureChannelInviteLinks(
          [slot.child],
          onLog: (msg, {String level = 'info'}) => track(msg),
          cancel: cancel,
        );
        await ChildPostJoinRunner.runFromJoinResults(
          tokenChildren: [slot.child],
          joinResults: result.results,
          templateFor: (_) => template,
          channelLinkFor: (child) =>
              channelLinks[child.id] ??
              channelPolicyFor(child.id).lastCreatedInviteUrl,
          onChatsSent: (child, chatIds, {messageIdsByChatId = const {}, titleByChatId = const {}}) =>
              rememberTemplateSends(
                child: child,
                chatIds: chatIds,
                templateId: template.id,
                messageIdsByChatId: messageIdsByChatId,
                titleByChatId: titleByChatId,
              ),
          onLog: (msg, {String level = 'info'}) => track(msg),
          rateSettings: rateSettings,
          cancel: cancel,
        );
        await addPipelineJournal(
          kind: PipelineJournalKind.templateOnJoin,
          message: '«${slot.child.label}» написал по шаблону «${template.name}»',
          motherAccountId: slot.mother.id,
          childAccountId: slot.child.id,
        );
      }

      doneSlots++;
      if (actionId != null) {
        updateActionProgress(actionId, done: doneSlots, total: plan.slots.length);
      }
    }

    final message = cancel?.isCancelled == true
        ? 'Остановлено: слотов $doneSlots, вступлений $joinedTotal'
        : 'Готово: слотов $doneSlots, вступлений $joinedTotal';
    return (joined: joinedTotal, slots: doneSlots, message: message);
  }

  /// Mother joins by invite links, then invites children by viewerId (for accounts
  /// that cannot join via link themselves — e.g. non-RU).
  Future<({int invited, int mothers, String message})> runPipelineChildrenJoinById({
    String? onlyMotherId,
    Set<String>? onlyChatIds,
    void Function(String message)? onLog,
    ActionCancelToken? cancel,
    String? actionId,
  }) async {
    void track(String msg) {
      onLog?.call(msg);
      if (actionId != null) updateActionProgress(actionId, message: msg);
    }

    final plan = buildPipelineLaunchPlan(
      alreadyJoinedChatIds: joinedChatIdsForPipeline(),
      onlyMotherId: onlyMotherId,
      onlyChatIds: onlyChatIds,
    );
    if (!plan.ok) {
      return (invited: 0, mothers: 0, message: plan.error ?? 'План пуст');
    }

    final byMother = <String, List<PipelineAssignSlot>>{};
    for (final slot in plan.slots) {
      byMother.putIfAbsent(slot.mother.id, () => []).add(slot);
    }

    var mothersDone = 0;
    var invitedTotal = 0;

    for (final entry in byMother.entries) {
      if (cancel?.isCancelled == true) break;
      final motherSlots = entry.value;
      final mother = motherSlots.first.mother;

      final unique = <String, MaxChannelCatalogEntry>{};
      for (final slot in motherSlots) {
        for (final g in slot.groups) {
          unique[g.chatId] = g;
        }
      }
      final uniqueGroups = unique.values.toList();

      track('Матка «${mother.label}»: вступление в ${uniqueGroups.length} групп…');
      final joinLinks = [
        for (final g in uniqueGroups)
          if (g.hasInviteLink) g.inviteUrl!,
      ];
      if (joinLinks.isEmpty) {
        track('«${mother.label}»: нет ссылок для вступления');
        mothersDone++;
        continue;
      }

      final motherProxy = mother.isolation.proxyServer?.trim();
      final motherProxyOrNull =
          (motherProxy != null && motherProxy.isNotEmpty) ? motherProxy : null;

      final joinResult = await MaxMotherService.joinGroups(
        token: mother.apiToken!,
        links: joinLinks,
        delayMs: rateSettings.motherJoinDelayMs,
        proxy: motherProxyOrNull,
        onProgress: track,
        cancel: cancel,
      );

      if (cancel?.isCancelled == true) break;

      // CLI died on login / empty response — don't pretend mother succeeded.
      if (!joinResult.ok && joinResult.results.isEmpty) {
        final msg = joinResult.message;
        final tokenDead = RegExp(
          r'login\.token|FAIL_LOGIN_TOKEN|авторизируйтесь|протух|Ошибка входа',
          caseSensitive: false,
        ).hasMatch(msg);
        track(
          tokenDead
              ? '«${mother.label}»: токен протух — ${msg}. '
                  'Войдите заново (QR / web.max.ru), потом повторите «Вступить / пригласить».'
              : '«${mother.label}»: вступление не удалось — $msg. Приглашение пропущено.',
        );
        if (tokenDead) {
          await addPipelineJournal(
            kind: PipelineJournalKind.launchPlan,
            message: '«${mother.label}»: токен протух, вход/приглашение остановлены',
            motherAccountId: mother.id,
            detail: msg,
          );
        }
        mothersDone++;
        if (actionId != null) {
          updateActionProgress(actionId, done: mothersDone, total: byMother.length);
        }
        continue;
      }

      await recordMembershipsFromJoinResults(
        motherAccountId: mother.id,
        children: const [],
        results: joinResult.results,
        titleByChatId: {for (final g in uniqueGroups) g.chatId: g.title},
      );
      await remapCatalogFromJoinResults(joinResult.results);

      // hash / synthetic catalog id → real chatId after mother join
      final resolvedChatId = <String, String>{};
      for (final row in joinResult.results) {
        if (row['ok'] != true) continue;
        final chatId = row['chatId']?.toString().trim() ?? '';
        if (chatId.isEmpty) continue;
        final hash = row['hash']?.toString().trim() ?? '';
        if (MotherGroupChannel.isValidInviteHash(hash)) {
          resolvedChatId[hash] = chatId;
          resolvedChatId['invite:$hash'] = chatId;
        }
      }
      for (final e in channelCatalog) {
        if (e.hasInviteLink && !e.chatId.startsWith('invite:')) {
          resolvedChatId[e.inviteHash!] = e.chatId;
          resolvedChatId['invite:${e.inviteHash!}'] = e.chatId;
        }
      }

      String? realChatIdFor(MaxChannelCatalogEntry g) {
        if (g.chatId.isNotEmpty && !g.chatId.startsWith('invite:')) {
          return g.chatId;
        }
        if (g.hasInviteLink && resolvedChatId.containsKey(g.inviteHash)) {
          return resolvedChatId[g.inviteHash];
        }
        return resolvedChatId[g.chatId];
      }

      for (final slot in motherSlots) {
        if (cancel?.isCancelled == true) break;
        await ensureViewerId(slot.child);
        final fresh = accountById(slot.child.id)!;
        final viewerId = fresh.viewerId;
        if (viewerId == null) {
          track('«${slot.child.label}»: нет viewerId — пропуск invite');
          continue;
        }

        final resolvedGroups = <MaxChannelCatalogEntry>[];
        final chatIds = <String>[];
        final groupsPayload = <Map<String, dynamic>>[];
        for (final g in slot.groups) {
          final chatId = realChatIdFor(g);
          if (chatId == null || chatId.isEmpty) {
            track('«${slot.child.label}»: нет chatId для «${g.title}» — пропуск');
            continue;
          }
          resolvedGroups.add(g);
          chatIds.add(chatId);
          groupsPayload.add({
            'chatId': chatId,
            'title': g.title,
            if (g.inviteHash != null) 'hash': g.inviteHash,
          });
        }
        if (chatIds.isEmpty) {
          track('«${slot.child.label}»: нечего приглашать');
          continue;
        }

        track('Приглашение «${slot.child.label}» → ${chatIds.length} групп (каскад ID→ссылка)');
        final childTargets = <Map<String, dynamic>>[];
        if (fresh.hasApiSession) {
          final childProxy = fresh.isolation.proxyServer?.trim();
          childTargets.add({
            'userId': viewerId,
            'token': fresh.apiToken!,
            if (fresh.phone != null) 'phone': fresh.phone!,
            if (childProxy != null && childProxy.isNotEmpty) 'proxy': childProxy,
          });
        }
        final inviteResult = await MaxMotherService.inviteChildren(
          motherToken: mother.apiToken!,
          links: const [],
          groups: groupsPayload,
          chatIds: chatIds,
          inviteUserIds: [viewerId],
          childTargets: childTargets,
          delayMs: rateSettings.motherJoinDelayMs,
          proxy: motherProxyOrNull,
          onProgress: track,
          cancel: cancel,
        );
        invitedTotal += inviteResult.invited + inviteResult.joined;

        if (!inviteResult.ok && inviteResult.results.isEmpty) {
          track(
            '«${slot.child.label}»: приглашение оборвалось — ${inviteResult.message}',
          );
        } else if (inviteResult.invited + inviteResult.joined == 0) {
          track(
            '«${slot.child.label}»: 0 приглашений'
            '${inviteResult.message.isNotEmpty ? ' (${inviteResult.message})' : ''}'
            '${inviteResult.failed > 0 ? ', ошибок: ${inviteResult.failed}' : ''}',
          );
        }

        await recordMembershipsFromJoinResults(
          motherAccountId: mother.id,
          children: [fresh],
          results: inviteResult.results,
          titleByChatId: {
            for (var i = 0; i < resolvedGroups.length; i++)
              chatIds[i]: resolvedGroups[i].title,
          },
        );
        await addPipelineJournal(
          kind: PipelineJournalKind.joinById,
          message: inviteResult.invited + inviteResult.joined > 0
              ? '«${slot.child.label}»: приглашений ${inviteResult.invited}'
              : '«${slot.child.label}»: приглашений 0 — ${inviteResult.message}',
          motherAccountId: mother.id,
          childAccountId: slot.child.id,
        );

        final template = joinTemplateForAccount(slot.child.id);
        if (template != null && template.isActive && inviteResult.invited > 0) {
          final channelLinks = await ensureChannelInviteLinks(
            [fresh],
            onLog: (msg, {String level = 'info'}) => track(msg),
            cancel: cancel,
          );
          await ChildPostJoinRunner.runPerAccountChats(
            children: [fresh],
            chatIdsByAccountId: {fresh.id: chatIds},
            templateFor: (_) => template,
            channelLinkFor: (child) =>
                channelLinks[child.id] ??
                channelPolicyFor(child.id).lastCreatedInviteUrl,
            onChatsSent: (child, sentChatIds, {messageIdsByChatId = const {}, titleByChatId = const {}}) =>
                rememberTemplateSends(
                  child: child,
                  chatIds: sentChatIds,
                  templateId: template.id,
                  messageIdsByChatId: messageIdsByChatId,
                  titleByChatId: titleByChatId,
                ),
            onLog: (msg, {String level = 'info'}) => track(msg),
            rateSettings: rateSettings,
            cancel: cancel,
          );
        }
      }

      mothersDone++;
      if (actionId != null) {
        updateActionProgress(actionId, done: mothersDone, total: byMother.length);
      }
    }

    final message = cancel?.isCancelled == true
        ? 'Остановлено: маток $mothersDone, приглашений $invitedTotal'
        : invitedTotal > 0
            ? 'Готово (по ID): маток $mothersDone, приглашений $invitedTotal'
            : 'По ID без приглашений: маток $mothersDone'
                '${rateSettings.motherJoinDelayMs >= 60000 ? ' · пауза ${rateSettings.motherJoinDelayMs ~/ 1000}с — на десятки групп это часы' : ''}';
    return (invited: invitedTotal, mothers: mothersDone, message: message);
  }

  void _startDailyTemplateTicker() {
    _dailyTemplateTimer?.cancel();
    _dailyTemplateTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_tickDailyTemplates());
      unawaited(_tickTemplateRepeats());
    });
  }

  Future<void> _tickTemplateRepeats() async {
    if (templateBroadcastRunning) return;
    final now = DateTime.now();
    for (final template in joinMessageTemplates) {
      if (!template.enabled || !template.repeatEnabled) continue;
      if (!template.hasMessages) continue;
      final interval = template.repeatIntervalMs;
      if (interval < 60000) continue;
      final last = _lastTemplateRepeatAt[template.id];
      if (last == null) {
        // Don't fire immediately on enable — wait one full interval.
        _lastTemplateRepeatAt[template.id] = now;
        continue;
      }
      if (now.difference(last).inMilliseconds < interval) continue;
      _lastTemplateRepeatAt[template.id] = now;
      browser.logMessage(
        '[Шаблон] повтор «${template.name}» каждые '
        '${(interval / 60000).toStringAsFixed(interval % 60000 == 0 ? 0 : 1)} мин',
      );
      try {
        await broadcastTemplateToExistingGroups(
          templateId: template.id,
          refreshGroups: false,
          scope: TemplateSendScope.all,
        );
      } catch (e) {
        browser.logMessage('[Шаблон] повтор ошибка: $e', level: 'error');
      }
    }
  }

  Future<void> _tickDailyTemplates() async {
    final now = DateTime.now();
    final dayKey = '${now.year}-${now.month}-${now.day}';
    // Drop yesterday keys so set stays small.
    _firedDailyKeys.removeWhere((k) => !k.startsWith(dayKey));

    for (final binding in matkaTemplateBindings) {
      if (!binding.enabled || binding.trigger != MatkaTemplateTrigger.dailyAt) {
        continue;
      }
      if (now.hour != binding.hour || now.minute != binding.minute) continue;
      final fireKey = '$dayKey::${binding.id}';
      if (_firedDailyKeys.contains(fireKey)) continue;
      _firedDailyKeys.add(fireKey);
      await _runDailyTemplateBinding(binding);
    }
  }

  Future<void> _runDailyTemplateBinding(MatkaTemplateBinding binding) async {
    final template = joinMessageTemplateById(binding.templateId);
    if (template == null || !template.isActive) return;
    final cluster = motherClusters.cast<MotherCluster?>().firstWhere(
          (c) => c?.motherAccountId == binding.motherAccountId,
          orElse: () => null,
        );
    if (cluster == null) return;
    final children = <MaxAccount>[
      for (final id in cluster.childAccountIds)
        if (accountById(id) case final a? when a.hasApiSession) a,
    ];
    if (children.isEmpty) return;

    await addPipelineJournal(
      kind: PipelineJournalKind.templateDaily,
      message:
          'Расписание ${binding.timeLabel}: «${template.name}» → ${children.length} дочек матки «${accountById(binding.motherAccountId)?.label ?? binding.motherAccountId}»',
      motherAccountId: binding.motherAccountId,
    );

    final action = beginAction(
      kind: ActiveActionKind.postJoinMessage,
      title: 'Шаблон ${binding.timeLabel}',
      subtitle: template.name,
    );
    try {
      final chatIdsByAccount = <String, List<String>>{};
      var skipped = 0;
      for (final child in children) {
        final chats = <String>[];
        for (final m in membershipsFor(child.id)) {
          if (storage.hasTemplateSent(
            accountId: child.id,
            chatId: m.chatId,
            templateId: binding.templateId,
          )) {
            skipped += 1;
            continue;
          }
          chats.add(m.chatId);
        }
        if (chats.isNotEmpty) chatIdsByAccount[child.id] = chats;
      }
      if (skipped > 0) {
        browser.logMessage('[Шаблон] расписание: пропуск уже слали $skipped');
      }
      if (chatIdsByAccount.isEmpty) {
        finishAction(action.id, message: 'Нет новых каналов у дочек');
        return;
      }
      final channelLinks = await ensureChannelInviteLinks(
        children,
        onLog: (msg, {String level = 'info'}) {
          browser.logMessage(msg, level: level);
          updateActionProgress(action.id, message: msg);
        },
        cancel: action.cancelToken,
      );
      final sent = await ChildPostJoinRunner.runPerAccountChats(
        children: children,
        chatIdsByAccountId: chatIdsByAccount,
        templateFor: (_) => template,
        channelLinkFor: (child) =>
            channelLinks[child.id] ?? channelPolicyFor(child.id).lastCreatedInviteUrl,
        onChatsSent: (child, chatIds, {messageIdsByChatId = const {}, titleByChatId = const {}}) =>
            rememberTemplateSends(
              child: child,
              chatIds: chatIds,
              templateId: binding.templateId,
              messageIdsByChatId: messageIdsByChatId,
              titleByChatId: titleByChatId,
            ),
        onLog: (msg, {String level = 'info'}) {
          browser.logMessage(msg, level: level);
          updateActionProgress(action.id, message: msg);
        },
        rateSettings: rateSettings,
        cancel: action.cancelToken,
        onProgress: (msg, {int? done, int? total}) {
          updateActionProgress(action.id, message: msg, done: done, total: total);
        },
      );
      finishAction(action.id, message: 'Отправлено сообщений: $sent');
    } catch (e) {
      finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
      await addPipelineJournal(
        kind: PipelineJournalKind.error,
        message: 'Ошибка daily шаблона: $e',
        motherAccountId: binding.motherAccountId,
      );
    }
  }

  /// Any account with a token may send join/template messages (incl. solo mother).
  bool canSendJoinMessages(String accountId) => true;

  Future<void> setAccountJoinTemplate(String accountId, String? templateId) async {
    final assign = Map<String, String>.from(storage.joinTemplateByAccountId);
    if (templateId == null || templateId.isEmpty) {
      assign.remove(accountId);
    } else if (joinMessageTemplateById(templateId) != null) {
      assign[accountId] = templateId;
    } else {
      return;
    }
    await _persistJoinTemplateAssignments(assign);
  }

  Future<void> applyJoinTemplateToAccounts({
    required String templateId,
    required Iterable<String> accountIds,
  }) async {
    if (joinMessageTemplateById(templateId) == null) return;
    final assign = Map<String, String>.from(storage.joinTemplateByAccountId);
    for (final accountId in accountIds) {
      assign[accountId] = templateId;
    }
    await _persistJoinTemplateAssignments(assign);
  }

  Future<void> clearJoinTemplateForAccounts(Iterable<String> accountIds) async {
    final assign = Map<String, String>.from(storage.joinTemplateByAccountId);
    for (final id in accountIds) {
      assign.remove(id);
    }
    await _persistJoinTemplateAssignments(assign);
  }

  Future<void> _persistProfileTemplates(List<ProfileTemplate> templates) async {
    await storage.saveProfileTemplates(templates);
    notifyListeners();
  }

  Future<void> _persistProfileTemplateAssignments(Map<String, String> assignments) async {
    await storage.saveProfileTemplateAssignments(assignments);
    notifyListeners();
  }

  Future<ProfileTemplate> addProfileTemplate({String? name}) async {
    final index = profileTemplates.length + 1;
    final template = ProfileTemplate.create(name: name ?? 'Профиль $index');
    await _persistProfileTemplates([...profileTemplates, template]);
    return template;
  }

  Future<void> updateProfileTemplate(ProfileTemplate template) async {
    final list =
        profileTemplates.map((t) => t.id == template.id ? template : t).toList();
    await _persistProfileTemplates(list);
  }

  Future<void> removeProfileTemplate(String templateId) async {
    await _persistProfileTemplates(
      profileTemplates.where((t) => t.id != templateId).toList(),
    );
    final assign = Map<String, String>.from(storage.profileTemplateByAccountId)
      ..removeWhere((_, id) => id == templateId);
    await _persistProfileTemplateAssignments(assign);
  }

  Future<void> setAccountProfileTemplate(String accountId, String? templateId) async {
    final assign = Map<String, String>.from(storage.profileTemplateByAccountId);
    if (templateId == null || templateId.isEmpty) {
      assign.remove(accountId);
    } else if (profileTemplateById(templateId) != null) {
      assign[accountId] = templateId;
    } else {
      return;
    }
    await _persistProfileTemplateAssignments(assign);
  }

  /// Copy template fields onto accounts, then push to MAX when token exists.
  Future<({int local, int pushed, int failed, List<String> errors})> applyProfileTemplateToAccounts({
    required String templateId,
    required Iterable<String> accountIds,
  }) async {
    final template = profileTemplateById(templateId);
    if (template == null) {
      return (local: 0, pushed: 0, failed: 0, errors: const <String>[]);
    }

    final ids = accountIds.toSet();
    var local = 0;
    var pushed = 0;
    var failed = 0;
    final errors = <String>[];
    final assign = Map<String, String>.from(storage.profileTemplateByAccountId);

    for (final account in List<MaxAccount>.from(storage.accounts)) {
      if (!ids.contains(account.id)) continue;
      final first = template.firstName?.trim() ?? '';
      final last = template.lastName?.trim() ?? '';
      final about = template.description?.trim() ?? '';
      final photo = template.photoPath?.trim() ?? '';
      // Only overwrite fields the template actually defines — keep the rest.
      final updated = account.copyWith(
        firstName: first.isNotEmpty ? first : null,
        lastName: last.isNotEmpty ? last : null,
        description: about.isNotEmpty ? about : null,
        profilePhotoPath: photo.isNotEmpty ? photo : null,
      );
      await storage.updateAccount(updated);
      if (selectedAccount?.id == account.id) {
        selectedAccount = updated;
      }
      assign[account.id] = templateId;
      local++;

      if (!updated.hasApiSession) {
        errors.add('${updated.label}: нет токена — только локально');
        continue;
      }
      final result = await pushAccountProfileToMax(updated);
      if (result.ok) {
        pushed++;
      } else {
        failed++;
        errors.add('${updated.label}: ${result.error ?? 'ошибка MAX'}');
      }
    }

    await _persistProfileTemplateAssignments(assign);
    return (local: local, pushed: pushed, failed: failed, errors: errors);
  }

  Future<void> clearProfileTemplateForAccounts(Iterable<String> accountIds) async {
    final assign = Map<String, String>.from(storage.profileTemplateByAccountId);
    for (final id in accountIds) {
      assign.remove(id);
    }
    await _persistProfileTemplateAssignments(assign);
  }

  /// Persist local profile fields and optionally push them to MAX.
  Future<MaxAuthResult?> updateAccountProfile({
    required String accountId,
    String? label,
    String? firstName,
    String? lastName,
    String? description,
    String? profilePhotoPath,
    bool clearFirstName = false,
    bool clearLastName = false,
    bool clearDescription = false,
    bool clearProfilePhoto = false,
    String? profileTemplateId,
    bool clearProfileTemplate = false,
    bool pushToMax = true,
  }) async {
    final account = accountById(accountId);
    if (account == null) return null;

    final updated = account.copyWith(
      label: label,
      firstName: firstName,
      lastName: lastName,
      description: description,
      profilePhotoPath: profilePhotoPath,
      clearFirstName: clearFirstName,
      clearLastName: clearLastName,
      clearDescription: clearDescription,
      clearProfilePhoto: clearProfilePhoto,
    );
    await storage.updateAccount(updated);
    if (selectedAccount?.id == accountId) {
      selectedAccount = updated;
    }

    if (clearProfileTemplate) {
      await setAccountProfileTemplate(accountId, null);
    } else if (profileTemplateId != null) {
      await setAccountProfileTemplate(accountId, profileTemplateId);
    } else {
      notifyListeners();
    }

    if (!pushToMax) return null;
    final fresh = accountById(accountId) ?? updated;
    if (!fresh.hasApiSession) {
      return MaxAuthResult(ok: false, error: 'Нет токена — сохранено только локально');
    }
    return pushAccountProfileToMax(fresh);
  }

  /// Push saved profile fields of [account] to MAX via opcode 16.
  Future<MaxAuthResult> pushAccountProfileToMax(MaxAccount account) async {
    if (!account.hasApiSession) {
      return MaxAuthResult(ok: false, error: 'Нет токена сессии');
    }
    final photo = account.profilePhotoPath?.trim();
    final result = await MaxAuthService.updateProfile(
      token: account.apiToken!,
      proxy: account.isolation.proxyServer,
      firstName: account.firstName,
      lastName: account.lastName,
      description: account.description,
      photoPath: (photo != null && photo.isNotEmpty && File(photo).existsSync())
          ? photo
          : null,
    );
    if (result.ok) {
      final merged = _mergeProfileFields(account, result).copyWith(
        healthStatus: AccountHealthStatus.ok,
        clearLastError: true,
        lastCheckedAt: DateTime.now(),
      );
      await storage.updateAccount(merged);
      if (selectedAccount?.id == account.id) {
        selectedAccount = merged;
      }
      notifyListeners();
    }
    return result;
  }

  List<AccountGroupMembership> membershipsFor(String accountId) =>
      storage.membershipsFor(accountId);

  Set<String> membershipChatIdsFor(String accountId) =>
      storage.membershipChatIdsFor(accountId);

  int membershipCountForAccounts(Iterable<String> accountIds) {
    final ids = accountIds.toSet();
    return storage.accountGroupMemberships.values
        .where((m) => ids.contains(m.accountId))
        .length;
  }

  Future<void> recordGroupMemberships(Iterable<AccountGroupMembership> items) async {
    await storage.upsertMemberships(items);
    notifyListeners();
  }

  Future<void> removeGroupMemberships({
    String? accountId,
    Iterable<String>? chatIds,
  }) async {
    await storage.removeMemberships(accountId: accountId, chatIds: chatIds);
    notifyListeners();
  }

  /// Сбросить учёт вступлений дочек выбранной матки по chatId (без выхода из MAX).
  Future<int> clearChildMembershipsForChats({
    required String motherAccountId,
    required Iterable<String> chatIds,
  }) async {
    final chats = chatIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (chats.isEmpty) return 0;
    final cluster = motherClusters.cast<MotherCluster?>().firstWhere(
          (c) => c?.motherAccountId == motherAccountId,
          orElse: () => null,
        );
    final childIds = cluster?.childAccountIds.toSet() ?? {};
    if (childIds.isEmpty) return 0;
    var removed = 0;
    final before = storage.accountGroupMemberships.length;
    await storage.removeMembershipsWhere(
      (m) => childIds.contains(m.accountId) && chats.contains(m.chatId),
    );
    removed = before - storage.accountGroupMemberships.length;
    notifyListeners();
    return removed;
  }

  Future<void> syncMembershipsFromListedGroups({
    required String accountId,
    required List<MotherGroupChannel> listed,
    Set<String>? expectedChatIds,
  }) async {
    await storage.syncMembershipsFromListedGroups(
      accountId: accountId,
      listed: listed,
      expectedChatIds: expectedChatIds,
    );
    notifyListeners();
  }

  /// Pull all chats the account is in via list-groups and replace local memberships.
  Future<MotherGroupsResult> refreshAccountMemberships(
    String accountId, {
    bool scanMessages = false,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    final account = accountById(accountId);
    if (account == null) {
      return MotherGroupsResult(ok: false, message: 'Аккаунт не найден');
    }
    if (!account.hasApiSession) {
      return MotherGroupsResult(ok: false, message: 'Нет токена сессии');
    }

    await ensureViewerId(account);
    final fresh = accountById(accountId) ?? account;
    final result = await MaxMotherService.listMotherGroups(
      token: fresh.apiToken!,
      scanMessages: scanMessages,
      proxy: fresh.isolation.proxyServer,
      onProgress: onProgress,
      cancel: cancel,
    );
    if (!result.ok) return result;

    await syncMembershipsFromListedGroups(
      accountId: accountId,
      listed: result.groups,
    );
    return MotherGroupsResult(
      ok: true,
      message: 'Групп: ${result.groups.length}',
      groups: result.groups,
    );
  }

  /// Record joins from mother CLI result rows.
  Future<void> recordMembershipsFromJoinResults({
    required String? motherAccountId,
    required List<MaxAccount> children,
    required List<Map<String, dynamic>> results,
    Map<String, String> titleByChatId = const {},
  }) async {
    final now = DateTime.now();
    final items = <AccountGroupMembership>[];

    for (final row in results) {
      if (row['ok'] != true) continue;
      final chatId = row['chatId']?.toString().trim() ?? '';
      if (chatId.isEmpty) continue;
      final phase = row['phase']?.toString();
      final method = row['method']?.toString();
      final title = (row['title']?.toString() ?? titleByChatId[chatId] ?? '').trim();

      if (phase == 'join' && motherAccountId != null) {
        items.add(AccountGroupMembership(
          accountId: motherAccountId,
          chatId: chatId,
          title: title,
          joinedAt: now,
          lastVerifiedAt: now,
        ));
        continue;
      }

      // Учитываем только реальное вступление / подтверждённый add_member.
      // phase=invite без method или после одной пересылки ссылки — не членство.
      final childJoined = phase == 'child_join';
      final invitedOk = phase == 'invite' &&
          (method == 'add_member' || method == 'already_member');
      if (!childJoined && !invitedOk) continue;

      MaxAccount? child;
      final idx = (row['childIndex'] as num?)?.toInt();
      if (idx != null && idx >= 0 && idx < children.length) {
        child = children[idx];
      } else {
        final userId = row['childUserId'];
        if (userId != null) {
          for (final a in children) {
            if (a.viewerId != null && a.viewerId.toString() == userId.toString()) {
              child = a;
              break;
            }
          }
        }
      }
      if (child == null) continue;
      items.add(AccountGroupMembership(
        accountId: child.id,
        chatId: chatId,
        title: title,
        joinedAt: now,
        lastVerifiedAt: now,
      ));
    }

    if (items.isNotEmpty) {
      await recordGroupMemberships(items);
    }
  }

  /// Check that [accountIds] are still members of [expectedGroups].
  Future<MembershipVerifySummary> verifyAccountsInGroups({
    required Iterable<String> accountIds,
    required List<MotherGroupChannel> expectedGroups,
    void Function(String message, {String level})? onLog,
  }) async {
    final expected = {
      for (final g in expectedGroups)
        if (g.chatId.isNotEmpty) g.chatId: g,
    };
    if (expected.isEmpty) {
      return const MembershipVerifySummary(rows: [], checked: 0, missingTotal: 0);
    }

    final rows = <MembershipVerifyRow>[];
    var missingTotal = 0;

    for (final accountId in accountIds) {
      final account = accountById(accountId);
      if (account == null) continue;
      final label = account.profileDisplayName;

      if (!account.hasApiSession) {
        onLog?.call('[Учёт] «$label» без токена — пропуск', level: 'warn');
        rows.add(MembershipVerifyRow(
          accountId: accountId,
          accountLabel: label,
          presentChatIds: const {},
          missingChatIds: expected.keys.toSet(),
          error: 'нет токена',
        ));
        missingTotal += expected.length;
        continue;
      }

      onLog?.call('[Учёт] проверяем «$label»…');
      try {
        await ensureViewerId(account);
        final fresh = accountById(accountId)!;
        final result = await MaxMotherService.listMotherGroups(
          token: fresh.apiToken!,
          scanMessages: false,
          proxy: fresh.isolation.proxyServer,
          onProgress: (msg) => onLog?.call(msg),
        );
        if (!result.ok) {
          onLog?.call('[Учёт] ✗ «$label»: ${result.message}', level: 'error');
          rows.add(MembershipVerifyRow(
            accountId: accountId,
            accountLabel: label,
            presentChatIds: const {},
            missingChatIds: expected.keys.toSet(),
            error: result.message,
          ));
          missingTotal += expected.length;
          continue;
        }

        final present = {
          for (final g in result.groups)
            if (g.chatId.isNotEmpty) g.chatId,
        };
        final missing = expected.keys.where((id) => !present.contains(id)).toSet();
        missingTotal += missing.length;

        await syncMembershipsFromListedGroups(
          accountId: accountId,
          listed: result.groups,
          expectedChatIds: expected.keys.toSet(),
        );

        if (missing.isEmpty) {
          onLog?.call('[Учёт] ✓ «$label» — во всех ${expected.length} группах');
        } else {
          final names = missing
              .map((id) => expected[id]?.title ?? id)
              .take(5)
              .join(', ');
          onLog?.call(
            '[Учёт] ✗ «$label» нет в ${missing.length}: $names'
            '${missing.length > 5 ? '…' : ''}',
            level: 'warn',
          );
        }

        rows.add(MembershipVerifyRow(
          accountId: accountId,
          accountLabel: label,
          presentChatIds: present.intersection(expected.keys.toSet()),
          missingChatIds: missing,
        ));
      } catch (e) {
        onLog?.call('[Учёт] ✗ «$label»: $e', level: 'error');
        rows.add(MembershipVerifyRow(
          accountId: accountId,
          accountLabel: label,
          presentChatIds: const {},
          missingChatIds: expected.keys.toSet(),
          error: e.toString(),
        ));
        missingTotal += expected.length;
      }
    }

    return MembershipVerifySummary(
      rows: rows,
      checked: rows.length,
      missingTotal: missingTotal,
    );
  }

  bool templateBroadcastRunning = false;

  /// Account ids that should write [templateId].
  /// Includes children with the template, and parents when cluster send mode is parent/solo.
  Set<String> joinTemplateWriterAccountIds(String templateId) {
    final mothers = accountMap.allMotherAccountIds;
    final ids = <String>{};

    for (final entry in storage.joinTemplateByAccountId.entries) {
      if (entry.value != templateId) continue;
      final accountId = entry.key;
      if (mothers.contains(accountId)) {
        final cluster = accountMap.clusterForMother(accountId);
        if (cluster == null) continue;
        if (cluster.effectiveSendMode == ClusterSendMode.parent) {
          ids.add(accountId);
        }
        continue;
      }
      ids.add(accountId);
    }

    // Solo / parent-mode clusters: mother must write even if assignment lagged.
    for (final cluster in motherClusters) {
      if (cluster.effectiveSendMode != ClusterSendMode.parent) continue;
      final mid = cluster.motherAccountId;
      if (mid == null) continue;
      final assigned = storage.joinTemplateByAccountId[mid];
      if (assigned == templateId) {
        ids.add(mid);
        continue;
      }
      // Binding to mother also counts.
      final bound = matkaTemplateBindings.any(
        (b) => b.enabled && b.templateId == templateId && b.motherAccountId == mid,
      );
      if (bound) ids.add(mid);
    }

    for (final binding in matkaTemplateBindings) {
      if (binding.templateId != templateId || !binding.enabled) continue;
      final cluster = accountMap.clusterForMother(binding.motherAccountId);
      if (cluster == null) continue;
      if (cluster.effectiveSendMode == ClusterSendMode.parent) {
        final mid = cluster.motherAccountId;
        if (mid != null) ids.add(mid);
      } else {
        for (final childId in cluster.childAccountIds) {
          if (!mothers.contains(childId)) ids.add(childId);
        }
      }
    }
    return ids;
  }

  /// Configure who sends for a parent cluster and assign [templateId] in one step.
  Future<void> applyClusterCampaignConfig({
    required String clusterId,
    required ClusterSendMode sendMode,
    String? templateId,
  }) async {
    final cluster = motherClusters.cast<MotherCluster?>().firstWhere(
          (c) => c?.id == clusterId,
          orElse: () => null,
        );
    if (cluster == null) return;

    final mode = cluster.isSolo ? ClusterSendMode.parent : sendMode;
    await updateMotherCluster(cluster.copyWith(sendMode: mode));

    final mid = cluster.motherAccountId;
    if (mid == null) return;

    final writers = <String>{
      if (mode == ClusterSendMode.parent) mid,
      if (mode == ClusterSendMode.children) ...cluster.childAccountIds,
    };
    final clearIds = <String>{
      mid,
      ...cluster.childAccountIds,
    };

    await clearJoinTemplateForAccounts(clearIds);
    if (templateId != null &&
        templateId.isNotEmpty &&
        joinMessageTemplateById(templateId) != null &&
        writers.isNotEmpty) {
      await applyJoinTemplateToAccounts(
        templateId: templateId,
        accountIds: writers,
      );
    }
  }

  List<TemplateSentRecord> templateSentHistory({
    String? templateId,
    String? accountId,
  }) {
    final list = storage.templateSentRecordsFor(
      templateId: templateId,
      accountId: accountId,
    )..sort((a, b) {
        final at = a.sentAt?.millisecondsSinceEpoch ?? 0;
        final bt = b.sentAt?.millisecondsSinceEpoch ?? 0;
        return bt.compareTo(at);
      });
    return list;
  }

  /// Send [template] into every group each eligible account is in.
  /// Optionally limit to [onlyAccountIds]. Reloads groups via list-groups when possible.
  Future<int> broadcastTemplateToExistingGroups({
    required String templateId,
    Iterable<String>? onlyAccountIds,
    Set<String>? onlyChatIds,
    bool refreshGroups = true,
    TemplateSendScope scope = TemplateSendScope.freshOnly,
  }) async {
    final template = joinMessageTemplateById(templateId);
    if (template == null || !template.isActive) {
      browser.logMessage('[Шаблон] нет активного шаблона', level: 'warn');
      return 0;
    }
    if (templateBroadcastRunning) {
      browser.logMessage('[Шаблон] уже идёт рассылка', level: 'warn');
      return 0;
    }

    var accountIds = joinTemplateWriterAccountIds(templateId);
    final filter = onlyAccountIds?.toSet();
    if (filter != null && filter.isNotEmpty) {
      final narrowed = accountIds.intersection(filter);
      // Explicit UI selection (e.g. solo parent) must not be wiped if assignment lagged.
      accountIds = narrowed.isNotEmpty ? narrowed : filter;
    }

    final targetAccounts = accounts
        .where(
          (a) =>
              accountIds.contains(a.id) &&
              a.hasApiSession &&
              canSendJoinMessages(a.id),
        )
        .toList();
    if (targetAccounts.isEmpty) {
      browser.logMessage(
        '[Шаблон] нет аккаунтов с токеном для «${template.name}» '
        '(проверьте «Кто шлёт» и назначение шаблона)',
        level: 'warn',
      );
      return 0;
    }

    templateBroadcastRunning = true;
    notifyListeners();
    final action = beginAction(
      kind: ActiveActionKind.postJoinMessage,
      title: 'Рассылка шаблона',
      subtitle: '«${template.name}» · ${targetAccounts.length} акк. · ${scope.title}',
    );
    browser.logMessage(
      '[Шаблон] «${template.name}» → ${targetAccounts.length} акк. '
      '(${scope.title})…',
    );

    try {
      final chatIdsByAccountId = <String, List<String>>{};
      var skippedAlready = 0;
      var skippedFresh = 0;

      for (final account in targetAccounts) {
        if (action.cancelToken.isCancelled) break;
        if (!canSendJoinMessages(account.id)) {
          continue;
        }

        var chatIds = <String>[];
        if (refreshGroups) {
          try {
            await ensureViewerId(account);
            final fresh = accountById(account.id)!;
            final listed = await MaxMotherService.listMotherGroups(
              token: fresh.apiToken!,
              scanMessages: false,
              proxy: fresh.isolation.proxyServer,
              onProgress: (msg) {
                browser.logMessage(msg);
                updateActionProgress(action.id, message: msg);
              },
              cancel: action.cancelToken,
            );
            if (listed.ok) {
              await syncMembershipsFromListedGroups(
                accountId: account.id,
                listed: listed.groups,
              );
              chatIds = [
                for (final g in listed.groups)
                  if (g.chatId.isNotEmpty) g.chatId,
              ];
              browser.logMessage(
                '[Шаблон] «${account.label}»: каналов ${chatIds.length}',
              );
            } else {
              browser.logMessage(
                '[Шаблон] «${account.label}»: не загрузили каналы — ${listed.message}',
                level: 'warn',
              );
            }
          } catch (e) {
            browser.logMessage(
              '[Шаблон] «${account.label}»: ошибка списка каналов: $e',
              level: 'error',
            );
          }
        }

        if (chatIds.isEmpty) {
          chatIds = membershipChatIdsFor(account.id).toList();
          if (chatIds.isNotEmpty) {
            browser.logMessage(
              '[Шаблон] «${account.label}»: из учёта ${chatIds.length} каналов',
            );
          }
        }

        // Fallback: groups known for this child's mother (invite/join flow).
        if (chatIds.isEmpty) {
          final cluster = clusterContainingAccount(account.id);
          final motherId = cluster?.motherAccountId;
          if (motherId != null && motherId != account.id) {
            final motherGroups = storage.motherGroupsFor(motherId);
            chatIds = [
              for (final g in motherGroups)
                if (g.chatId.isNotEmpty) g.chatId,
            ];
            if (chatIds.isNotEmpty) {
              browser.logMessage(
                '[Шаблон] «${account.label}»: каналы матки «${accountById(motherId)?.label ?? motherId}» '
                '(${chatIds.length})',
              );
            }
          }
        }

        if (chatIds.isEmpty) {
          browser.logMessage(
            '[Шаблон] «${account.label}»: нет каналов — пропуск',
            level: 'warn',
          );
          continue;
        }

        final filtered = <String>[];
        for (final chatId in chatIds) {
          if (onlyChatIds != null &&
              onlyChatIds.isNotEmpty &&
              !onlyChatIds.contains(chatId)) {
            continue;
          }
          final already = storage.hasTemplateSent(
            accountId: account.id,
            chatId: chatId,
            templateId: templateId,
          );
          switch (scope) {
            case TemplateSendScope.freshOnly:
              if (already) {
                skippedAlready += 1;
              } else {
                filtered.add(chatId);
              }
            case TemplateSendScope.alreadySentOnly:
              if (already) {
                filtered.add(chatId);
              } else {
                skippedFresh += 1;
              }
            case TemplateSendScope.all:
              filtered.add(chatId);
          }
        }

        if (filtered.isEmpty) {
          browser.logMessage(
            '[Шаблон] «${account.label}»: после фильтра (${scope.title}) 0 каналов',
          );
          continue;
        }
        chatIdsByAccountId[account.id] = filtered;
        browser.logMessage(
          '[Шаблон] «${account.label}»: к отправке ${filtered.length}'
          '${scope == TemplateSendScope.freshOnly && skippedAlready > 0 ? ' (пропуск уже слали)' : ''}',
        );
      }

      if (skippedAlready > 0) {
        browser.logMessage('[Шаблон] пропущено уже слали: $skippedAlready');
      }
      if (skippedFresh > 0) {
        browser.logMessage('[Шаблон] пропущено без истории: $skippedFresh');
      }

      if (chatIdsByAccountId.isEmpty) {
        browser.logMessage(
          '[Шаблон] некуда писать — каналы не найдены / всё уже слали',
          level: 'warn',
        );
        finishAction(
          action.id,
          status: ActiveActionStatus.failed,
          message: scope == TemplateSendScope.freshOnly
              ? 'Нечего слать — всё уже отправлено'
              : 'Каналы не найдены',
        );
        return 0;
      }

      final ready = targetAccounts
          .where(
            (a) =>
                chatIdsByAccountId.containsKey(a.id) && canSendJoinMessages(a.id),
          )
          .toList();
      final channelLinks = await ensureChannelInviteLinks(
        ready,
        onLog: (msg, {String level = 'info'}) {
          browser.logMessage(msg, level: level);
          updateActionProgress(action.id, message: msg);
        },
        cancel: action.cancelToken,
      );
      final sent = await ChildPostJoinRunner.runPerAccountChats(
        children: ready,
        chatIdsByAccountId: chatIdsByAccountId,
        templateFor: (_) => template,
        channelLinkFor: (child) =>
            channelLinks[child.id] ?? channelPolicyFor(child.id).lastCreatedInviteUrl,
        delayBeforeMs: 0,
        rateSettings: rateSettings,
        cancel: action.cancelToken,
        onChatsSent: (child, chatIds, {messageIdsByChatId = const {}, titleByChatId = const {}}) =>
            rememberTemplateSends(
              child: child,
              chatIds: chatIds,
              templateId: templateId,
              messageIdsByChatId: messageIdsByChatId,
              titleByChatId: titleByChatId,
            ),
        onLog: (msg, {String level = 'info'}) {
          browser.logMessage(msg, level: level);
          updateActionProgress(action.id, message: msg);
        },
        onProgress: (msg, {int? done, int? total}) {
          updateActionProgress(action.id, message: msg, done: done, total: total);
        },
      );
      if (action.cancelToken.isCancelled) {
        finishAction(action.id, status: ActiveActionStatus.cancelled, message: 'Отправлено: $sent');
      } else if (sent == 0) {
        finishAction(
          action.id,
          status: ActiveActionStatus.failed,
          message: 'Ничего не отправлено (нет {channel_link} или каналов)',
        );
        browser.logMessage('[Шаблон] готово: отправлено 0', level: 'error');
      } else {
        finishAction(action.id, message: 'Отправлено сообщений: $sent');
        browser.logMessage('[Шаблон] готово: отправлено $sent');
        if (template.repeatEnabled) {
          _lastTemplateRepeatAt[templateId] = DateTime.now();
        }
      }
      return sent;
    } catch (e) {
      finishAction(action.id, status: ActiveActionStatus.failed, message: e.toString());
      rethrow;
    } finally {
      templateBroadcastRunning = false;
      notifyListeners();
    }
  }

  ChannelFunnel? channelFunnelById(String? id) {
    if (id == null) return null;
    for (final f in channelFunnels) {
      if (f.id == id) return f;
    }
    return null;
  }

  Future<void> _persistChannelFunnels(List<ChannelFunnel> funnels) async {
    await storage.saveChannelFunnels(funnels);
    notifyListeners();
  }

  Future<void> _persistChannelPolicies(Map<String, AccountChannelPolicy> policies) async {
    await storage.saveChannelPolicies(policies);
    notifyListeners();
  }

  Future<ChannelFunnel> addChannelFunnel({String? name}) async {
    final index = channelFunnels.length + 1;
    final funnel = ChannelFunnel.create(name: name ?? 'Воронка $index');
    await _persistChannelFunnels([...channelFunnels, funnel]);
    return funnel;
  }

  Future<void> updateChannelFunnel(ChannelFunnel funnel) async {
    final list = channelFunnels.map((f) => f.id == funnel.id ? funnel : f).toList();
    await _persistChannelFunnels(list);
  }

  Future<void> removeChannelFunnel(String funnelId) async {
    await _persistChannelFunnels(
      channelFunnels.where((f) => f.id != funnelId).toList(),
    );
    // Drop funnel refs from account policies.
    final policies = Map<String, AccountChannelPolicy>.from(storage.channelPoliciesByAccountId);
    var changed = false;
    for (final entry in policies.entries.toList()) {
      if (!entry.value.funnelIds.contains(funnelId)) continue;
      final nextIds = {...entry.value.funnelIds}..remove(funnelId);
      policies[entry.key] = entry.value.copyWith(funnelIds: nextIds);
      changed = true;
    }
    if (changed) await _persistChannelPolicies(policies);
  }

  Future<void> setAccountChannelPolicy(AccountChannelPolicy policy) async {
    final policies = Map<String, AccountChannelPolicy>.from(storage.channelPoliciesByAccountId);
    final cleanedIds = policy.funnelIds.intersection(channelFunnels.map((f) => f.id).toSet());
    final next = policy.copyWith(funnelIds: cleanedIds);
    final hasChannel = (next.lastCreatedChatId?.trim().isNotEmpty == true) ||
        (next.lastCreatedInviteUrl?.trim().isNotEmpty == true);
    if (!next.canCreateChannels && next.funnelIds.isEmpty && !hasChannel) {
      policies.remove(next.accountId);
    } else {
      policies[next.accountId] = next;
    }
    await _persistChannelPolicies(policies);
  }

  /// Cached invite URL, or fetch from [lastCreatedChatId] / own CHANNEL created earlier.
  Future<String?> ensureChannelInviteUrl(
    MaxAccount account, {
    void Function(String message, {String level})? onLog,
    ActionCancelToken? cancel,
  }) async {
    if (!account.hasApiSession) return null;
    final policy = channelPolicyFor(account.id);
    final cached = policy.lastCreatedInviteUrl?.trim();
    if (cached != null && cached.isNotEmpty) return cached;

    final knownChatId = policy.lastCreatedChatId?.trim();
    onLog?.call(
      knownChatId != null && knownChatId.isNotEmpty
          ? '[Канал] «${account.label}»: берём ссылку для chatId $knownChatId…'
          : '[Канал] «${account.label}»: канал мог быть создан раньше — ищем свой CHANNEL…',
    );

    final result = await MaxMotherService.resolveChannelInvite(
      token: account.apiToken!,
      chatId: (knownChatId != null && knownChatId.isNotEmpty) ? knownChatId : null,
      proxy: account.isolation.proxyServer,
      onProgress: (msg) => onLog?.call(msg),
      cancel: cancel,
    );
    if (!result.ok || result.inviteUrl == null || result.inviteUrl!.trim().isEmpty) {
      onLog?.call(
        '[Канал] «${account.label}»: ${result.message}',
        level: 'warn',
      );
      return null;
    }

    final url = result.inviteUrl!.trim();
    await setAccountChannelPolicy(
      policy.copyWith(
        lastCreatedChatId: result.chatId ?? knownChatId,
        lastCreatedTitle: result.title ?? policy.lastCreatedTitle,
        lastCreatedInviteUrl: url,
      ),
    );
    onLog?.call('[Канал] «${account.label}»: ссылка сохранена → $url');
    return url;
  }

  Future<Map<String, String>> ensureChannelInviteLinks(
    Iterable<MaxAccount> accounts, {
    void Function(String message, {String level})? onLog,
    ActionCancelToken? cancel,
  }) async {
    final out = <String, String>{};
    for (final account in accounts) {
      if (cancel?.isCancelled == true) break;
      final url = await ensureChannelInviteUrl(
        account,
        onLog: onLog,
        cancel: cancel,
      );
      if (url != null && url.isNotEmpty) out[account.id] = url;
    }
    return out;
  }

  Future<void> setAccountCanCreateChannels(String accountId, bool value) async {
    final current = channelPolicyFor(accountId);
    await setAccountChannelPolicy(current.copyWith(canCreateChannels: value));
  }

  /// Drop cached funnel channel so the next run creates a new one.
  Future<void> clearAccountCreatedChannel(String accountId) async {
    final current = channelPolicyFor(accountId);
    if (current.lastCreatedChatId == null &&
        current.lastCreatedInviteUrl == null &&
        current.lastCreatedTitle == null) {
      return;
    }
    await setAccountChannelPolicy(current.copyWith(clearLastCreated: true));
    browser.logMessage(
      '[Воронка] сброшен сохранённый канал у «${accountById(accountId)?.label ?? accountId}»',
    );
  }

  Future<void> setAccountFunnelIds(String accountId, Set<String> funnelIds) async {
    final current = channelPolicyFor(accountId);
    await setAccountChannelPolicy(current.copyWith(funnelIds: funnelIds));
  }

  Future<void> toggleAccountFunnel(String accountId, String funnelId, bool enabled) async {
    final current = channelPolicyFor(accountId);
    final next = {...current.funnelIds};
    if (enabled) {
      next.add(funnelId);
    } else {
      next.remove(funnelId);
    }
    await setAccountChannelPolicy(current.copyWith(funnelIds: next));
  }

  Future<void> applyFunnelToAccounts({
    required String funnelId,
    required Iterable<String> accountIds,
    bool canCreateChannels = true,
  }) async {
    if (channelFunnelById(funnelId) == null) return;
    final policies = Map<String, AccountChannelPolicy>.from(storage.channelPoliciesByAccountId);
    for (final accountId in accountIds) {
      final current = policies[accountId] ?? AccountChannelPolicy(accountId: accountId);
      policies[accountId] = current.copyWith(
        canCreateChannels: canCreateChannels || current.canCreateChannels,
        funnelIds: {...current.funnelIds, funnelId},
      );
    }
    await _persistChannelPolicies(policies);
  }

  Future<FunnelRunSummary> runChannelFunnel(String funnelId) async {
    final funnel = channelFunnelById(funnelId);
    if (funnel == null) {
      return FunnelRunSummary(
        ok: false,
        processed: 0,
        succeeded: 0,
        failed: 0,
        message: 'Воронка не найдена',
      );
    }
    if (funnelRunning) {
      return FunnelRunSummary(
        ok: false,
        processed: 0,
        succeeded: 0,
        failed: 0,
        message: 'Воронка уже запущена',
      );
    }
    funnelRunning = true;
    final action = beginAction(
      kind: ActiveActionKind.funnel,
      title: 'Воронка «${funnel.name}»',
      subtitle: 'Создание каналов',
    );
    notifyListeners();
    try {
      final summary = await _funnelRunner.run(
        funnel: funnel,
        accounts: accounts,
        clusters: motherClusters,
        policyFor: channelPolicyFor,
        savePolicy: setAccountChannelPolicy,
        onLog: (msg, {String level = 'info'}) => browser.logMessage(msg, level: level),
        cancel: action.cancelToken,
        onProgress: (message, {int? done, int? total}) {
          updateActionProgress(action.id, message: message, done: done, total: total);
        },
      );
      finishAction(
        action.id,
        status: summary.cancelled
            ? ActiveActionStatus.cancelled
            : (summary.ok ? ActiveActionStatus.completed : ActiveActionStatus.failed),
        message: summary.message,
      );
      return summary;
    } catch (e) {
      finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.failed,
        message: e.toString(),
      );
      rethrow;
    } finally {
      funnelRunning = false;
      notifyListeners();
    }
  }

  /// Publish funnel posts into already-created channels (no channel create).
  Future<FunnelRunSummary> publishChannelFunnelPosts(
    String funnelId, {
    Set<String>? accountIds,
  }) async {
    final funnel = channelFunnelById(funnelId);
    if (funnel == null) {
      return FunnelRunSummary(
        ok: false,
        processed: 0,
        succeeded: 0,
        failed: 0,
        message: 'Воронка не найдена',
      );
    }
    if (funnelRunning) {
      return FunnelRunSummary(
        ok: false,
        processed: 0,
        succeeded: 0,
        failed: 0,
        message: 'Воронка уже запущена',
      );
    }
    funnelRunning = true;
    final action = beginAction(
      kind: ActiveActionKind.funnel,
      title: 'Посты «${funnel.name}»',
      subtitle: 'Публикация в созданные каналы',
    );
    notifyListeners();
    try {
      final summary = await _funnelRunner.publishOnly(
        funnel: funnel,
        accounts: accounts,
        clusters: motherClusters,
        policyFor: channelPolicyFor,
        savePolicy: setAccountChannelPolicy,
        accountIds: accountIds,
        onLog: (msg, {String level = 'info'}) => browser.logMessage(msg, level: level),
        cancel: action.cancelToken,
        onProgress: (message, {int? done, int? total}) {
          updateActionProgress(action.id, message: message, done: done, total: total);
        },
      );
      finishAction(
        action.id,
        status: summary.cancelled
            ? ActiveActionStatus.cancelled
            : (summary.ok ? ActiveActionStatus.completed : ActiveActionStatus.failed),
        message: summary.message,
      );
      return summary;
    } catch (e) {
      finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.failed,
        message: e.toString(),
      );
      rethrow;
    } finally {
      funnelRunning = false;
      notifyListeners();
    }
  }

  Future<void> _persistAccountMap(AccountMapState map) async {
    await storage.saveAccountMap(map);
    _syncBroadcastSchedules();
    notifyListeners();
  }

  Future<void> updateRateSettings(RateSettings settings) async {
    await storage.saveRateSettings(settings);
    notifyListeners();
  }

  void _syncBroadcastSchedules() {
    _broadcastRunner.syncSchedules(
      nodes: accountMap.workflowNodes,
      edges: accountMap.workflowEdges,
      accounts: accounts,
      rateSettings: rateSettings,
      onLog: (msg, {String level = 'info'}) => browser.logMessage(msg, level: level),
      onScheduledRun: (node) => runBroadcastWorkflow(node.id),
    );
  }

  void setNavPage(AppNavPage page) {
    // Legacy route: mother tools live on Запуск / Раздача / Профили.
    if (page == AppNavPage.mother) page = AppNavPage.launch;
    if (navPage == page) return;
    navPage = page;
    notifyListeners();
  }

  void selectWorkflowNode(String? nodeId) {
    selectedWorkflowNodeId = nodeId;
    if (nodeId != null) {
      final node = accountMap.workflowNodes.byId(nodeId);
      if (node?.isGroup == true) {
        final ownerId = ownerAccountIdForGroup(nodeId);
        if (ownerId != null && selectedAccount?.id != ownerId) {
          for (final a in accounts) {
            if (a.id == ownerId) {
              selectedAccount = a;
              break;
            }
          }
        }
        navPage = AppNavPage.groups;
      } else if (node?.isBroadcast == true && node!.parentGroupId != null) {
        final ownerId = ownerAccountIdForGroup(node.parentGroupId!);
        if (ownerId != null && selectedAccount?.id != ownerId) {
          for (final a in accounts) {
            if (a.id == ownerId) {
              selectedAccount = a;
              break;
            }
          }
        }
        navPage = AppNavPage.groups;
      }
    }
    notifyListeners();
  }

  String? ownerAccountIdForGroup(String groupId) {
    for (final edge in accountMap.workflowEdges) {
      if (edge.kind == WorkflowEdgeKind.owner && edge.toId == groupId) {
        return edge.fromId;
      }
    }
    return null;
  }

  List<MapWorkflowNode> groupsForAccount(String accountId) {
    final groupIds = accountMap.workflowEdges
        .where((e) => e.kind == WorkflowEdgeKind.owner && e.fromId == accountId)
        .map((e) => e.toId)
        .toSet();
    return workflowNodes.where((n) => n.isGroup && groupIds.contains(n.id)).toList();
  }

  List<MapWorkflowNode> broadcastsInGroup(String groupId) {
    return workflowNodes.where((n) => n.isBroadcast && n.parentGroupId == groupId).toList();
  }

  /// Mother account whose MAX groups should be used for [accountId]
  /// (the account itself if it is a mother / not in a cluster).
  String chatCatalogAccountId(String accountId) {
    if (accountMap.isMotherAccount(accountId)) return accountId;
    for (final c in motherClusters) {
      if (c.childAccountIds.contains(accountId) && c.motherAccountId != null) {
        return c.motherAccountId!;
      }
    }
    return accountId;
  }

  MotherCluster? clusterContainingAccount(String accountId) {
    for (final c in motherClusters) {
      if (c.motherAccountId == accountId || c.childAccountIds.contains(accountId)) {
        return c;
      }
    }
    return null;
  }

  /// Rich channel list for the account's mother catalog (never mixes mothers).
  List<MotherGroupChannel> motherChannelsForAccount(String accountId) {
    final catalogId = chatCatalogAccountId(accountId);
    return List<MotherGroupChannel>.from(storage.motherGroupsFor(catalogId));
  }

  /// Чаты/группы MAX, доступные для выбора у аккаунта (из кэша матки + WS).
  List<String> availableChatsForAccount(String accountId) {
    final catalogId = chatCatalogAccountId(accountId);
    final names = <String>{};
    for (final group in storage.motherGroupsFor(catalogId)) {
      final title = group.title.trim();
      if (title.isNotEmpty) names.add(title);
    }
    // Live WS titles only when connected as this mother — avoid mixing other sessions.
    if (selectedAccount?.id == catalogId && maxWs.isConnected) {
      for (final title in maxWs.chatTitles.values) {
        final t = title.trim();
        if (t.isNotEmpty) names.add(t);
      }
    }
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Загружает список групп/чатов матки (для дочернего — каталог её матки).
  Future<void> refreshAccountChatCatalog(String accountId) async {
    final catalogId = chatCatalogAccountId(accountId);
    final account = accountById(catalogId);
    if (account == null || !account.hasApiSession) {
      throw StateError(
        catalogId != accountId
            ? 'У матки нет API-токена — загрузите чаты через аккаунт матки'
            : 'У аккаунта нет API-токена',
      );
    }
    browser.logMessage('Загрузка групп MAX для матки «${account.label}»…');
    final result = await MaxMotherService.listMotherGroups(
      token: account.apiToken!,
      scanMessages: false,
      proxy: account.isolation.proxyServer,
      onProgress: (line) => browser.logMessage(line),
    );
    if (!result.ok) {
      throw StateError(result.message);
    }
    await storage.mergeMotherGroups(catalogId, result.groups);
    browser.logMessage('Групп в каталоге матки «${account.label}»: ${result.groups.length}');

    if (selectedAccount?.id == catalogId) {
      try {
        await maxWs.connect(
          token: account.apiToken!,
          deviceId: account.webDeviceId,
          viewerId: account.viewerId,
          targetChats: const [],
          proxyUrl: account.isolation.proxyServer,
        );
        browser.logMessage('[WS] Чатов в каталоге: ${maxWs.chatTitles.length}');
      } catch (e) {
        browser.logMessage('[WS] Каталог чатов: $e', level: 'warn');
      }
      await _syncAiWs();
    }
    notifyListeners();
  }

  Future<MapWorkflowNode> addWorkflowGroup({
    double? x,
    double? y,
    String? accountId,
  }) async {
    final ownerId = accountId ?? selectedAccount?.id;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final n = accountMap.workflowNodes.where((w) => w.isGroup).length;
    final basePos = ownerId != null ? positionForAccount(ownerId) : const Offset(880, 60);
    final node = MapWorkflowNode(
      id: id,
      kind: MapWorkflowNodeKind.group,
      title: 'Группа ${n + 1}',
      x: x ?? basePos.dx + 220,
      y: y ?? basePos.dy + (groupsForAccount(ownerId ?? '').length * 40),
      width: 340,
      height: 240,
      group: const GroupWorkflowConfig(),
    );

    final edges = [...accountMap.workflowEdges];
    if (ownerId != null) {
      edges.removeWhere((e) => e.kind == WorkflowEdgeKind.owner && e.toId == id);
      edges.add(WorkflowMapEdge(fromId: ownerId, toId: id, kind: WorkflowEdgeKind.owner));
    }

    await _persistAccountMap(
      accountMap.copyWith(
        workflowNodes: [...accountMap.workflowNodes, node],
        workflowEdges: edges,
      ),
    );
    selectedWorkflowNodeId = id;
    return node;
  }

  Future<MapWorkflowNode> addWorkflowGroupForAccount(String accountId) {
    return addWorkflowGroup(accountId: accountId);
  }

  Future<MapWorkflowNode> addWorkflowBroadcast({
    double? x,
    double? y,
    String? parentGroupId,
  }) async {
    final groupId = parentGroupId ?? selectedWorkflowNodeId;
    final parent = groupId != null ? accountMap.workflowNodes.byId(groupId) : null;
    final resolvedGroupId = parent?.isGroup == true ? parent!.id : null;

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final n = accountMap.workflowNodes.where((w) => w.isBroadcast).length;
    final groupNode = resolvedGroupId != null ? accountMap.workflowNodes.byId(resolvedGroupId) : null;
    final childCount = resolvedGroupId != null ? broadcastsInGroup(resolvedGroupId).length : 0;
    final basePos = groupNode != null ? Offset(groupNode.x, groupNode.y) : const Offset(920, 120);

    final senderId = selectedAccount?.id ?? (resolvedGroupId != null ? ownerAccountIdForGroup(resolvedGroupId) : null);

    final node = MapWorkflowNode(
      id: id,
      kind: MapWorkflowNodeKind.broadcast,
      title: 'Рассылка ${n + 1}',
      x: x ?? basePos.dx + 36,
      y: y ?? basePos.dy + 72 + childCount * 150.0,
      parentGroupId: resolvedGroupId,
      broadcast: BroadcastWorkflowConfig(
        senderAccountId: senderId,
        steps: [
          BroadcastMessageStep(
            id: '${id}_1',
            text: 'Привет! Это тестовое сообщение.',
            delayAfterMs: 5000,
          ),
        ],
      ),
    );

    final edges = [...accountMap.workflowEdges];
    if (resolvedGroupId != null) {
      edges.removeWhere((e) => e.kind == WorkflowEdgeKind.contains && e.toId == id);
      edges.add(WorkflowMapEdge(fromId: resolvedGroupId, toId: id, kind: WorkflowEdgeKind.contains));
    }
    if (senderId != null) {
      edges.removeWhere((e) => e.kind == WorkflowEdgeKind.sender && e.toId == id);
      edges.add(WorkflowMapEdge(fromId: senderId, toId: id, kind: WorkflowEdgeKind.sender));
    }

    await _persistAccountMap(
      accountMap.copyWith(
        workflowNodes: [...accountMap.workflowNodes, node],
        workflowEdges: edges,
      ),
    );
    selectedWorkflowNodeId = id;
    return node;
  }

  Future<void> updateWorkflowNode(MapWorkflowNode node) async {
    final nodes = accountMap.workflowNodes.map((n) => n.id == node.id ? node : n).toList();
    await _persistAccountMap(accountMap.copyWith(workflowNodes: nodes));
  }

  Future<void> deleteWorkflowNode(String id) async {
    final nodes = accountMap.workflowNodes
        .where((n) => n.id != id)
        .map((n) => n.parentGroupId == id ? n.copyWith(parentGroupId: null) : n)
        .toList();
    final edges = accountMap.workflowEdges
        .where((e) => e.fromId != id && e.toId != id)
        .toList();
    if (selectedWorkflowNodeId == id) selectedWorkflowNodeId = null;
    await _persistAccountMap(accountMap.copyWith(workflowNodes: nodes, workflowEdges: edges));
  }

  Future<void> moveWorkflowNode(String id, Offset position, {double? width, double? height}) async {
    final nodes = accountMap.workflowNodes.map((n) {
      if (n.id != id) return n;
      return n.copyWith(x: position.dx, y: position.dy, width: width, height: height);
    }).toList();
    await _persistAccountMap(accountMap.copyWith(workflowNodes: nodes));
  }

  Future<void> addWorkflowSenderEdge({
    required String accountId,
    required String workflowId,
  }) async {
    final edges = accountMap.workflowEdges
        .where((e) => !(e.toId == workflowId && e.kind == WorkflowEdgeKind.sender))
        .toList()
      ..add(WorkflowMapEdge(fromId: accountId, toId: workflowId, kind: WorkflowEdgeKind.sender));

    final nodes = accountMap.workflowNodes.map((n) {
      if (n.id != workflowId || !n.isBroadcast) return n;
      return n.copyWith(broadcast: n.broadcast?.copyWith(senderAccountId: accountId));
    }).toList();

    await _persistAccountMap(accountMap.copyWith(workflowNodes: nodes, workflowEdges: edges));
  }

  Future<void> setWorkflowParent({required String nodeId, String? groupId}) async {
    final nodes = accountMap.workflowNodes.map((n) {
      if (n.id != nodeId) return n;
      return n.copyWith(parentGroupId: groupId);
    }).toList();
    await _persistAccountMap(accountMap.copyWith(workflowNodes: nodes));
  }

  Future<void> linkGroupToAccount({
    required String groupId,
    required String accountId,
  }) async {
    final edges = accountMap.workflowEdges
        .where((e) => !(e.kind == WorkflowEdgeKind.owner && e.toId == groupId))
        .toList()
      ..add(WorkflowMapEdge(fromId: accountId, toId: groupId, kind: WorkflowEdgeKind.owner));
    await _persistAccountMap(accountMap.copyWith(workflowEdges: edges));
  }

  Future<void> repairWorkflowContainsEdges() async {
    final edges = [...accountMap.workflowEdges];
    var changed = false;
    for (final node in accountMap.workflowNodes.where((n) => n.isBroadcast && n.parentGroupId != null)) {
      final parentId = node.parentGroupId!;
      final exists = edges.any(
        (e) => e.kind == WorkflowEdgeKind.contains && e.fromId == parentId && e.toId == node.id,
      );
      if (!exists) {
        edges.add(WorkflowMapEdge(fromId: parentId, toId: node.id, kind: WorkflowEdgeKind.contains));
        changed = true;
      }
    }
    if (changed) {
      await _persistAccountMap(accountMap.copyWith(workflowEdges: edges));
    }
  }

  String? senderAccountIdForWorkflow(String workflowId) {
    final node = accountMap.workflowNodes.byId(workflowId);
    if (node == null) return null;
    return _broadcastRunner.resolveSenderId(node, accountMap.workflowEdges);
  }

  Future<void> runBroadcastWorkflow(String nodeId) async {
    final node = accountMap.workflowNodes.byId(nodeId);
    if (node == null) return;
    final action = beginAction(
      kind: ActiveActionKind.broadcast,
      title: 'Рассылка «${node.title}»',
      subtitle: node.broadcast == null
          ? null
          : '${node.broadcast!.targetChats.length} чатов · ${node.broadcast!.steps.length} сообщ.',
    );
    try {
      await _broadcastRunner.runBroadcast(
        node: node,
        edges: accountMap.workflowEdges,
        accounts: accounts,
        rateSettings: rateSettings,
        onLog: (msg, {String level = 'info'}) => browser.logMessage(msg, level: level),
        cancel: action.cancelToken,
        onProgress: (message, {int? done, int? total}) {
          updateActionProgress(action.id, message: message, done: done, total: total);
        },
      );
      finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
      );
    } catch (e) {
      finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.failed,
        message: e.toString(),
      );
    }
    notifyListeners();
  }

  Future<void> _persistMotherClusters(List<MotherCluster> clusters) async {
    final cleaned = clusters
        .map(
          (c) => c.copyWith(
            childAccountIds: {
              for (final id in c.childAccountIds)
                if (id != c.motherAccountId) id,
            },
          ),
        )
        .toList();
    final withEdges = accountMap.copyWith(
      motherClusters: cleaned,
      edges: AccountMapState(motherClusters: cleaned).edgesFromClusters(),
    );
    await _persistAccountMap(withEdges);
  }

  Future<MotherCluster> addMotherCluster({String? name, String? motherAccountId}) async {
    final index = accountMap.motherClusters.length + 1;
    final cluster = MotherCluster.create(
      name: name ?? 'Родитель $index',
      motherAccountId: motherAccountId,
    );
    await _persistMotherClusters([...accountMap.motherClusters, cluster]);
    return cluster;
  }

  Future<void> updateMotherCluster(MotherCluster cluster) async {
    final list = accountMap.motherClusters.map((c) => c.id == cluster.id ? cluster : c).toList();
    if (!list.any((c) => c.id == cluster.id)) {
      list.add(cluster);
    }
    await _persistMotherClusters(list);
  }

  Future<void> removeMotherCluster(String clusterId) async {
    await _persistMotherClusters(
      accountMap.motherClusters.where((c) => c.id != clusterId).toList(),
    );
  }

  /// Updates one cluster's mother/children.
  ///
  /// When [stealFromOthers] is true (default), accounts already used by other
  /// clusters are moved here — linking/re-linking works without channels.
  Future<void> setMotherClusterRelations({
    required String clusterId,
    String? motherId,
    Set<String>? childIds,
    bool clearMother = false,
    bool stealFromOthers = true,
  }) async {
    final existing = accountMap.clusterById(clusterId);
    if (existing == null) return;

    final nextMother = clearMother ? null : (motherId ?? existing.motherAccountId);
    final requestedChildren = childIds ?? existing.childAccountIds;
    final stealIds = <String>{
      if (stealFromOthers && nextMother != null) nextMother,
      if (stealFromOthers)
        for (final id in requestedChildren)
          if (id != nextMother) id,
    };

    var clusters = accountMap.motherClusters.map((c) {
      if (c.id == clusterId) return c;
      if (stealIds.isEmpty) return c;
      final clearOtherMother = c.motherAccountId != null && stealIds.contains(c.motherAccountId);
      final nextKids = {...c.childAccountIds}..removeWhere(stealIds.contains);
      if (!clearOtherMother && nextKids.length == c.childAccountIds.length) {
        return c;
      }
      return c.copyWith(
        clearMother: clearOtherMother,
        childAccountIds: nextKids,
      );
    }).toList();

    final occupied = <String>{};
    for (final c in clusters) {
      if (c.id == clusterId) continue;
      if (c.motherAccountId != null) occupied.add(c.motherAccountId!);
      occupied.addAll(c.childAccountIds);
    }

    if (nextMother != null && occupied.contains(nextMother)) {
      return;
    }
    final nextChildren = {
      for (final id in requestedChildren)
        if (id != nextMother && !occupied.contains(id)) id,
    };

    clusters = [
      for (final c in clusters)
        if (c.id == clusterId)
          existing.copyWith(
            motherAccountId: nextMother,
            childAccountIds: nextChildren,
            clearMother: clearMother,
          )
        else
          c,
    ];
    await _persistMotherClusters(clusters);
    // Newly appointed mothers must not keep write templates.
    if (nextMother != null) {
      await clearJoinTemplateForAccounts([nextMother]);
    }
  }

  /// Legacy helper — updates the first cluster (creates one if needed).
  Future<void> setMotherRelations({String? motherId, Set<String>? childIds}) async {
    if (accountMap.motherClusters.isEmpty) {
      await addMotherCluster(motherAccountId: motherId);
      if (childIds != null && accountMap.motherClusters.isNotEmpty) {
        await setMotherClusterRelations(
          clusterId: accountMap.motherClusters.first.id,
          motherId: motherId,
          childIds: childIds,
        );
      }
      return;
    }
    await setMotherClusterRelations(
      clusterId: accountMap.motherClusters.first.id,
      motherId: motherId,
      childIds: childIds,
      clearMother: motherId == null,
    );
  }

  Future<void> pruneMotherClustersForRemovedAccount(String accountId) async {
    final next = <MotherCluster>[];
    var changed = false;
    for (final c in accountMap.motherClusters) {
      var cluster = c;
      if (c.motherAccountId == accountId) {
        cluster = c.copyWith(clearMother: true, childAccountIds: c.childAccountIds);
        changed = true;
      }
      if (c.childAccountIds.contains(accountId)) {
        cluster = cluster.copyWith(
          childAccountIds: {...cluster.childAccountIds}..remove(accountId),
        );
        changed = true;
      }
      next.add(cluster);
    }
    if (changed) await _persistMotherClusters(next);
  }

  Offset positionForAccount(String accountId) {
    final existing = accountMap.positions.where((p) => p.accountId == accountId).toList();
    if (existing.isNotEmpty) return existing.first.offset;

    final index = accounts.indexWhere((a) => a.id == accountId);
    final i = index < 0 ? accounts.length : index;
    final col = i % 3;
    final row = i ~/ 3;
    return Offset(140 + col * 300.0, 100 + row * 540.0);
  }

  Future<void> moveAccountOnMap(String accountId, Offset position) async {
    final others = accountMap.positions.where((p) => p.accountId != accountId).toList();
    others.add(AccountNodePosition(accountId: accountId, x: position.dx, y: position.dy));
    await _persistAccountMap(
      accountMap.copyWith(
        positions: others,
      ),
    );
  }

  void recordMapActivity({
    String? fromAccountId,
    String? toAccountId,
    required AccountMapActivityType type,
    required String message,
  }) {
    mapActivity = AccountMapActivity(
      fromAccountId: fromAccountId,
      toAccountId: toAccountId,
      type: type,
      message: message,
      at: DateTime.now(),
    );
    _mapActivityTimer?.cancel();
    _mapActivityTimer = Timer(const Duration(seconds: 8), () {
      mapActivity = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void setBrowserDrawerOpen(bool open) {
    if (browserDrawerOpen == open) return;
    browserDrawerOpen = open;
    notifyListeners();
  }

  Future<void> openAccountOnMap(MaxAccount account) async {
    await selectAccount(account);
    browserDrawerOpen = true;
    notifyListeners();
  }

  List<MaxAccount> get accounts => storage.accounts;

  List<AutomationRule> rulesForSelected() {
    final account = selectedAccount;
    if (account == null) return [];
    return storage.rulesFor(account.id);
  }

  List<MacroScenario> scenariosForSelected() {
    final account = selectedAccount;
    if (account == null) return [];
    return storage.scenariosFor(account.id);
  }

  AiChatConfig aiConfigForSelected() {
    final account = selectedAccount;
    if (account == null) return AiChatConfig.defaults('');
    return storage.aiConfigFor(account.id);
  }

  Future<void> saveAiConfig(AiChatConfig config) async {
    await storage.saveAiConfig(config);
    if (selectedAccount?.id == config.accountId) {
      await _syncAiWs();
    }
    notifyListeners();
  }

  Future<void> reconnectAiWs() async {
    await maxWs.disconnect();
    await _syncAiWs();
  }

  bool _aiProcessing = false;
  final Set<String> _aiHandledKeys = {};

  Future<void> handleIncomingMessage(
    String key,
    String text,
    String? chatTitle, {
    String? chatId,
  }) async {
    if (_aiProcessing) {
      browser.logMessage('[ИИ] Обработчик: уже идёт запрос к API, пропуск', level: 'warn');
      return;
    }
    if (_aiHandledKeys.contains(key)) {
      browser.logMessage('[ИИ] Обработчик: ключ $key уже обработан', level: 'warn');
      return;
    }

    final account = selectedAccount;
    if (account == null) {
      browser.logMessage('[ИИ] Обработчик: нет выбранного аккаунта', level: 'error');
      return;
    }
    if (browser.activeAccount?.id != account.id) {
      browser.logMessage('[ИИ] Обработчик: аккаунт не совпадает', level: 'warn');
      return;
    }

    final config = storage.aiConfigFor(account.id);
    if (!config.enabled) {
      browser.logMessage('[ИИ] Обработчик: ИИ выключен в настройках', level: 'warn');
      return;
    }
    if (!config.isConfigured) {
      browser.logMessage('[ИИ] Обработчик: API не настроен (ключ или URL пустой)', level: 'error');
      return;
    }

    _aiProcessing = true;
    _aiHandledKeys.add(key);

    browser.logMessage('[ИИ] Обработка: «${chatTitle ?? 'чат'}» ← «$text»');

    try {
      final reply = await AiChatService.complete(
        config: config,
        userMessage: text,
        chatTitle: chatTitle,
        onLog: (msg, {String level = 'info'}) => browser.logMessage(msg, level: level),
      );
      browser.logMessage('[ИИ] Отправка ответа через WS (${reply.length} симв.)…');
      if (!maxWs.isConnected) {
        browser.logMessage('[ИИ] ✗ WS не подключён — нажмите «Переподключить WS»', level: 'error');
        _aiHandledKeys.remove(key);
        return;
      }

      final targetChatId = chatId ??
          (config.targetChats.isNotEmpty
              ? maxWs.resolveChatIdForTarget(config.targetChats.first)
              : null);

      if (targetChatId == null) {
        browser.logMessage(
          '[ИИ] ✗ Не найден chatId. Чаты WS: ${maxWs.chatTitles.entries.map((e) => '${e.value}=${e.key}').join(', ')}',
          level: 'error',
        );
        _aiHandledKeys.remove(key);
        return;
      }

      await maxWs.sendMessage(targetChatId, reply);
      browser.logMessage('[ИИ] ✓ Ответ отправлен в чат ${maxWs.chatTitleFor(targetChatId) ?? targetChatId}');
    } on AiChatException catch (e) {
      browser.logMessage('[ИИ] ✗ API ошибка: ${e.message}', level: 'error');
      _aiHandledKeys.remove(key);
    } catch (e) {
      browser.logMessage('[ИИ] ✗ Ошибка: $e', level: 'error');
      _aiHandledKeys.remove(key);
    } finally {
      _aiProcessing = false;
    }
    notifyListeners();
  }

  /// Принудительный ответ ИИ в открытый чат (для теста — обходит фильтр исходящих).
  Future<void> triggerTestReplyInChat(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      browser.logMessage('[ИИ] Тест: пустое сообщение', level: 'warn');
      return;
    }

    final config = aiConfigForSelected();
    if (!config.enabled) {
      browser.logMessage('[ИИ] Тест: включите ИИ-ответы', level: 'warn');
      return;
    }
    if (!config.isConfigured) {
      browser.logMessage('[ИИ] Тест: настройте API-ключ', level: 'error');
      return;
    }

    final chatTitle = config.targetChats.isNotEmpty
        ? maxWs.chatTitleFor(maxWs.resolveChatIdForTarget(config.targetChats.first) ?? '')
        : null;
    final chatId = config.targetChats.isNotEmpty
        ? maxWs.resolveChatIdForTarget(config.targetChats.first)
        : maxWs.chatTitles.keys.isNotEmpty
            ? maxWs.chatTitles.keys.first
            : null;

    browser.logMessage('[ИИ] Тест: «$trimmed» → чат ${chatTitle ?? chatId ?? '?'}');

    final key = 'test:${DateTime.now().millisecondsSinceEpoch}';
    await handleIncomingMessage(key, trimmed, chatTitle, chatId: chatId);
  }

  Future<void> _syncAiWs() async {
    final account = selectedAccount;
    maxWs.onLog = (message, {String level = 'info'}) =>
        browser.logMessage(message, level: level);

    if (account == null) {
      await maxWs.disconnect();
      return;
    }

    final config = storage.aiConfigFor(account.id);
    if (!config.enabled) {
      await maxWs.disconnect();
      browser.logMessage('[ИИ] WS отключён (ИИ выключен)');
      return;
    }

    if (!account.hasApiSession) {
      browser.logMessage('[ИИ] WS недоступен — добавьте аккаунт с токеном', level: 'error');
      return;
    }

    maxWs.onIncoming = (msg) {
      unawaited(handleIncomingMessage(
        msg.dedupeKey,
        msg.text,
        msg.chatTitle,
        chatId: msg.chatId,
      ));
    };

    try {
      await maxWs.connect(
        token: account.apiToken!,
        deviceId: account.webDeviceId,
        viewerId: account.viewerId,
        targetChats: config.targetChats,
        proxyUrl: account.isolation.proxyServer,
      );
      if (config.targetChats.isNotEmpty) {
        final resolved = maxWs.resolveChatIdForTarget(config.targetChats.first);
        browser.logMessage(
          resolved != null
              ? '[ИИ] Цель «${config.targetChats.first}» → chatId $resolved'
              : '[ИИ] Чат «${config.targetChats.first}» пока не найден в WS — ждите синхронизацию',
          level: resolved != null ? 'info' : 'warn',
        );
      }
    } catch (e) {
      browser.logMessage('[ИИ] WS ошибка: $e', level: 'error');
    }
  }

  Future<void> bootstrap({bool openBrowser = true}) async {
    await repairWorkflowContainsEdges();
    if (accounts.isNotEmpty) {
      await selectAccountById(accounts.first.id, openBrowser: openBrowser);
    }
    _syncBroadcastSchedules();
    notifyListeners();
  }

  Future<void> selectAccountById(String id, {bool openBrowser = true}) async {
    MaxAccount? found;
    for (final a in accounts) {
      if (a.id == id) {
        found = a;
        break;
      }
    }
    if (found == null) return;
    if (openBrowser) {
      await selectAccount(found);
    } else {
      selectedAccount = found;
      editingScenario = null;
      _scheduler.stopAll();
      notifyListeners();
      unawaited(_autoRefreshProfileIfNeeded(found));
      await _syncAiWs();
      _syncScenarioSchedules();
      notifyListeners();
    }
  }

  Future<MaxAccount> addAccount(String label) async {
    final account = await storage.addAccount(label);
    notifyListeners();
    await selectAccountById(account.id, openBrowser: true);
    return account;
  }

  Future<MaxAccount> addAccountFromSms({
    required String phone,
    required String apiToken,
    String? label,
  }) async {
    final account = await storage.addAccountFromSms(
      phone: phone,
      apiToken: apiToken,
      label: label,
    );
    notifyListeners();
    await selectAccountById(account.id, openBrowser: true);
    return account;
  }

  Future<MaxAccount> addAccountFromToken({
    required String apiToken,
    String? phone,
    String? label,
    int? viewerId,
    String? proxyServer,
    String? deviceId,
    bool openBrowser = true,
    AccountHealthStatus healthStatus = AccountHealthStatus.unknown,
    String? lastError,
  }) async {
    final account = await storage.addAccountFromToken(
      apiToken: apiToken,
      phone: phone,
      label: label,
      viewerId: viewerId,
      proxyServer: proxyServer,
      deviceId: deviceId,
      healthStatus: healthStatus,
      lastError: lastError,
    );
    notifyListeners();
    if (openBrowser) {
      await selectAccountById(account.id, openBrowser: true);
    }
    return account;
  }

  /// Bulk create from parsed token files. Does not open a browser per account.
  Future<List<MaxAccount>> addAccountsFromTokenImports({
    required List<
            ({
              String apiToken,
              String? label,
              String? phone,
              int? viewerId,
              String? deviceId,
              AccountHealthStatus healthStatus,
            })>
        items,
    String? proxyServer,
  }) async {
    final created = <MaxAccount>[];
    final existingTokens = accounts
        .map((a) => a.apiToken)
        .whereType<String>()
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet();

    for (final item in items) {
      final token = item.apiToken.trim();
      if (token.isEmpty || existingTokens.contains(token)) continue;
      existingTokens.add(token);
      final account = await storage.addAccountFromToken(
        apiToken: token,
        label: item.label,
        phone: item.phone,
        viewerId: item.viewerId,
        proxyServer: proxyServer,
        deviceId: item.deviceId,
        healthStatus: item.healthStatus,
      );
      created.add(account);
    }

    if (created.isNotEmpty) {
      notifyListeners();
      await selectAccountById(created.last.id, openBrowser: false);
    }
    return created;
  }

  Future<void> applyCapturedToken(String token, String? phone) async {
    final account = selectedAccount;
    if (account == null || account.apiToken == token) return;

    final updated = account.copyWith(
      apiToken: token,
      phone: phone ?? account.phone,
      authMethod: MaxAuthMethod.token,
      healthStatus: AccountHealthStatus.unknown,
      clearLastError: true,
    );
    await storage.updateAccount(updated);
    selectedAccount = updated;
    await _syncAiWs();
    notifyListeners();
  }

  /// Resolves MAX user id via token API (needed for mother-account invites).
  Future<int?> ensureViewerId(MaxAccount account) async {
    if (account.viewerId != null) return account.viewerId;
    if (!account.hasApiSession) return null;

    final result = await MaxAuthService.verifyToken(
      account.apiToken!,
      proxy: account.isolation.proxyServer,
    );
    await _applyHealthFromResult(account, result);
    if (!result.ok || result.profileId == null) return null;

    final fresh = accountById(account.id) ?? account;
    final updated = fresh.copyWith(
      viewerId: result.profileId,
      phone: result.profilePhone ?? fresh.phone,
      authMethod: MaxAuthMethod.token,
    );
    await storage.updateAccount(updated);
    if (selectedAccount?.id == account.id) {
      selectedAccount = updated;
    }
    notifyListeners();
    return result.profileId;
  }

  /// Pull name / phone / viewerId from MAX API for an existing account.
  Future<MaxAuthResult> refreshAccountProfile(MaxAccount account) async {
    if (!account.hasApiSession) {
      return MaxAuthResult(ok: false, error: 'Нет токена сессии');
    }

    final result = await MaxAuthService.verifyToken(
      account.apiToken!,
      proxy: account.isolation.proxyServer,
    );
    final withHealth = await _applyHealthFromResult(account, result);
    if (!result.ok) return result;

    final updated = _mergeProfileFields(withHealth, result);
    await storage.updateAccount(updated);
    if (selectedAccount?.id == account.id) {
      selectedAccount = updated;
    }
    notifyListeners();
    return result;
  }

  /// Re-check login-by-token and persist health status.
  Future<MaxAuthResult> checkAccountHealth(MaxAccount account) async {
    if (!account.hasApiSession) {
      final updated = account.copyWith(
        healthStatus: AccountHealthStatus.unknown,
        lastError: 'Нет токена сессии',
        lastCheckedAt: DateTime.now(),
      );
      await storage.updateAccount(updated);
      if (selectedAccount?.id == account.id) selectedAccount = updated;
      notifyListeners();
      return MaxAuthResult(ok: false, error: 'Нет токена сессии');
    }

    final result = await MaxAuthService.verifyToken(
      account.apiToken!,
      proxy: account.isolation.proxyServer,
    );
    final withHealth = await _applyHealthFromResult(account, result);
    if (result.ok) {
      final updated = _mergeProfileFields(withHealth, result);
      await storage.updateAccount(updated);
      if (selectedAccount?.id == account.id) selectedAccount = updated;
      notifyListeners();
    }
    return result;
  }

  MaxAccount _mergeProfileFields(MaxAccount account, MaxAuthResult result) {
    final first = result.profileFirstName?.trim();
    final last = result.profileLastName?.trim();
    final composed = [
      if (first != null && first.isNotEmpty) first,
      if (last != null && last.isNotEmpty) last,
    ].join(' ');
    final name = (result.profileName != null && result.profileName!.trim().isNotEmpty)
        ? result.profileName!.trim()
        : (composed.isNotEmpty ? composed : account.label);
    return account.copyWith(
      label: name,
      firstName: (first != null && first.isNotEmpty) ? first : account.firstName,
      lastName: (last != null && last.isNotEmpty) ? last : account.lastName,
      description: result.profileDescription?.trim().isNotEmpty == true
          ? result.profileDescription!.trim()
          : account.description,
      viewerId: result.profileId ?? account.viewerId,
      phone: result.profilePhone ?? result.phone ?? account.phone,
      authMethod: MaxAuthMethod.token,
    );
  }

  /// Check all token accounts sequentially. Returns counts by status.
  Future<Map<AccountHealthStatus, int>> checkAllAccountHealth({
    void Function(int done, int total, MaxAccount account)? onProgress,
  }) async {
    final list = accountsWithToken();
    final counts = <AccountHealthStatus, int>{};
    for (var i = 0; i < list.length; i++) {
      final account = accountById(list[i].id) ?? list[i];
      final result = await checkAccountHealth(account);
      final status = result.healthStatus;
      counts[status] = (counts[status] ?? 0) + 1;
      onProgress?.call(i + 1, list.length, accountById(account.id) ?? account);
    }
    return counts;
  }

  Future<MaxAccount> _applyHealthFromResult(MaxAccount account, MaxAuthResult result) async {
    final status = result.healthStatus;
    final updated = account.copyWith(
      healthStatus: status,
      lastError: result.ok ? null : (result.error ?? result.code),
      clearLastError: result.ok,
      lastCheckedAt: DateTime.now(),
    );
    await storage.updateAccount(updated);
    if (selectedAccount?.id == account.id) {
      selectedAccount = updated;
    }
    notifyListeners();
    return updated;
  }

  List<MaxAccount> accountsWithToken() =>
      accounts.where((a) => a.hasApiSession).toList();

  MaxAccount? accountById(String? id) {
    if (id == null) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Reads API token from web.max.ru profile (for QR accounts).
  Future<bool> captureTokenFromBrowser(MaxAccount account) async {
    if (browser.activeAccount?.id != account.id) {
      await selectAccount(account);
    }

    for (var i = 0; i < 24; i++) {
      if (browser.controller?.value.isInitialized == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    final session = await browser.readStoredAuthSession();
    if (session == null) {
      browser.logMessage(
        'Токен не найден. Откройте «${account.label}» в MAX и дождитесь загрузки чатов.',
        level: 'warn',
      );
      return false;
    }

    final updated = account.copyWith(
      apiToken: session.token,
      viewerId: session.viewerId ?? account.viewerId,
      authMethod: MaxAuthMethod.token,
    );
    await storage.updateAccount(updated);
    if (selectedAccount?.id == account.id) {
      selectedAccount = updated;
      await _syncAiWs();
    }
    browser.logMessage('Токен «${account.label}» сохранён — матка доступна');
    notifyListeners();
    return true;
  }

  Future<void> updateAccountEmulator(MaxAccount account, EmulatorProfile emulator) async {
    final updated = account.copyWith(emulator: emulator);
    await storage.updateAccount(updated);
    if (selectedAccount?.id == account.id) {
      selectedAccount = updated;
    }
    notifyListeners();
  }

  Future<void> removeAccount(MaxAccount account) async {
    if (browser.activeAccount?.id == account.id) {
      _scheduler.stopAll();
      await browser.close();
    }
    await pruneMotherClustersForRemovedAccount(account.id);
    await storage.removeAccount(account.id);
    if (selectedAccount?.id == account.id) {
      selectedAccount = accounts.isNotEmpty ? accounts.first : null;
      if (selectedAccount != null) {
        await selectAccount(selectedAccount!);
      }
    }
    notifyListeners();
  }

  Future<void> selectAccount(MaxAccount account) async {
    selectedAccount = account;
    editingScenario = null;
    _scheduler.stopAll();
    notifyListeners();
    unawaited(_autoRefreshProfileIfNeeded(account));
    await browser.openAccount(account);
    await _syncAiWs();
    _syncScenarioSchedules();
    notifyListeners();
  }

  final Set<String> _profileRefreshInFlight = {};

  bool _needsProfileRefresh(MaxAccount account) {
    if (!account.hasApiSession) return false;
    final noName = account.firstName?.trim().isNotEmpty != true &&
        account.lastName?.trim().isNotEmpty != true;
    final noPhone = account.phone?.trim().isNotEmpty != true;
    return account.healthStatus == AccountHealthStatus.unknown || (noName && noPhone);
  }

  Future<void> _autoRefreshProfileIfNeeded(MaxAccount account) async {
    if (!_needsProfileRefresh(account)) return;
    if (!_profileRefreshInFlight.add(account.id)) return;
    try {
      await refreshAccountProfile(account);
    } catch (_) {
      // Best-effort; user can still press «Инфо».
    } finally {
      _profileRefreshInFlight.remove(account.id);
    }
  }

  void _syncScenarioSchedules() {
    final account = selectedAccount;
    if (account == null) return;
    _scheduler.sync(
      activeAccountId: account.id,
      scenarios: storage.scenarios,
      runner: _runScheduledScenario,
    );
  }

  Future<void> _runScheduledScenario(MacroScenario scenario) async {
    await _executeScenario(scenario);
    await storage.updateScenario(scenario.copyWith(lastRunAt: DateTime.now()));
    notifyListeners();
  }

  static bool _scenarioSendsChatMessages(MacroScenario scenario) {
    for (final step in scenario.steps) {
      switch (step.type) {
        case MacroStepType.typeText:
        case MacroStepType.clickSend:
        case MacroStepType.pressEnter:
        case MacroStepType.emulatorInputText:
        case MacroStepType.emulatorPressEnter:
          return true;
        default:
          break;
      }
    }
    return false;
  }

  Future<void> _executeScenario(MacroScenario scenario) async {
    MaxAccount? account;
    for (final a in storage.accounts) {
      if (a.id == scenario.accountId) {
        account = a;
        break;
      }
    }

    if (scenario.isEmulator) {
      account ??= selectedAccount;
      if (account == null) {
        browser.logMessage('Сценарий эмулятора: аккаунт не найден', level: 'error');
        return;
      }
      try {
        await EmulatorMacroRunner.instance.runScenario(
          account,
          scenario,
          onLog: (m) => browser.logMessage(m),
        );
      } catch (e) {
        browser.logMessage('Ошибка сценария эмулятора: $e', level: 'error');
      }
      return;
    }

    if (account == null) {
      browser.logMessage(
        'Сценарий «${scenario.name}»: аккаунт не найден',
        level: 'error',
      );
      return;
    }

    final browserReady = browser.activeAccount?.id == account.id &&
        browser.controller?.value.isInitialized == true;
    if (!browserReady) {
      browser.logMessage(
        'Сценарий «${scenario.name}»: открываю браузер «${account.label}»…',
      );
      selectedAccount = account;
      notifyListeners();
      await browser.openAccount(account);
      await _syncAiWs();
    }

    if (browser.controller?.value.isInitialized != true) {
      final detail = browser.error?.trim();
      browser.logMessage(
        detail == null || detail.isEmpty
            ? 'Сценарий «${scenario.name}»: браузер не готов'
            : 'Сценарий «${scenario.name}»: браузер не готов — $detail',
        level: 'error',
      );
      return;
    }

    await browser.runScenario(scenario);
  }

  Future<void> addKeywordRule({
    required String name,
    required String keywordsRaw,
    required String replyText,
  }) async {
    final account = selectedAccount;
    if (account == null) return;

    final rule = AutomationRule(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      accountId: account.id,
      name: name,
      type: AutomationRuleType.keywordReply,
      enabled: true,
      keywords: keywordsRaw
          .split(',')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList(),
      replyText: replyText,
    );

    await storage.addRule(rule);
    await browser.syncAutomation(storage.rulesFor(account.id));
    notifyListeners();
  }

  Future<void> toggleRule(AutomationRule rule, bool enabled) async {
    await storage.updateRule(rule.copyWith(enabled: enabled));
    final account = selectedAccount;
    if (account != null) {
      await browser.syncAutomation(storage.rulesFor(account.id));
    }
    notifyListeners();
  }

  Future<void> removeRule(AutomationRule rule) async {
    await storage.removeRule(rule.id);
    final account = selectedAccount;
    if (account != null) {
      await browser.syncAutomation(storage.rulesFor(account.id));
    }
    notifyListeners();
  }

  Future<void> setAutomationEnabled(bool value) async {
    automationEnabled = value;
    await browser.syncAutomation(rulesForSelected(), enabled: value);
    notifyListeners();
  }

  Future<void> updateAccountIsolation(
    MaxAccount account, {
    String? proxyServer,
    bool regenerateFingerprint = false,
  }) async {
    var isolation = account.isolation;
    if (regenerateFingerprint) {
      isolation = ProfileFingerprint.generate('${account.id}-${DateTime.now().microsecondsSinceEpoch}');
    }
    if (proxyServer != null) {
      final trimmed = proxyServer.trim();
      isolation = isolation.copyWith(
        proxyServer: trimmed.isEmpty ? null : trimmed,
        clearProxy: trimmed.isEmpty,
      );
    }

    final updated = account.copyWith(isolation: isolation);
    await storage.updateAccount(updated);

    if (selectedAccount?.id == account.id) {
      selectedAccount = updated;
      await browser.openAccount(updated);
    }
    notifyListeners();
  }

  /// Sets the same proxy on every account (API + browser).
  Future<void> applyProxyToAllAccounts(String? proxyServer) async {
    final trimmed = proxyServer?.trim();
    final value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    for (final account in List<MaxAccount>.from(accounts)) {
      final isolation = account.isolation.copyWith(
        proxyServer: value,
        clearProxy: value == null,
      );
      final updated = account.copyWith(isolation: isolation);
      await storage.updateAccount(updated);
      if (selectedAccount?.id == account.id) {
        selectedAccount = updated;
      }
    }
    if (selectedAccount != null) {
      await browser.openAccount(selectedAccount!);
    }
    notifyListeners();
  }

  Future<void> regenerateFingerprint(MaxAccount account) {
    return updateAccountIsolation(account, regenerateFingerprint: true);
  }

  void startNewScenario({MacroTarget target = MacroTarget.web}) {
    final account = selectedAccount;
    if (account == null) return;
    editingScenario = MacroScenario(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      accountId: account.id,
      name: target == MacroTarget.emulator ? 'Сценарий эмулятора' : 'Новый сценарий',
      steps: [],
      target: target,
    );
    if (target == MacroTarget.emulator) {
      emulatorPanelVisible = true;
      emulatorMirrorMode = EmulatorMirrorMode.control;
    }
    notifyListeners();
  }

  void setEditingScenarioTarget(MacroTarget target) {
    final draft = editingScenario;
    if (draft == null || draft.target == target) return;
    editingScenario = draft.copyWith(target: target);
    notifyListeners();
  }

  void setEmulatorPanelVisible(bool visible) {
    emulatorPanelVisible = visible;
    if (visible) emulatorFocusMode = false;
    notifyListeners();
  }

  void setEmulatorFocusMode(bool focus) {
    emulatorFocusMode = focus;
    if (focus) emulatorPanelVisible = true;
    notifyListeners();
  }

  void setEmulatorNativeClickMode(bool enabled) {
    emulatorNativeClickMode = enabled;
    notifyListeners();
  }

  void setEmulatorClickerVisible(bool visible) {
    emulatorClickerVisible = visible;
    notifyListeners();
  }

  void setEmulatorWebFraction(double fraction) {
    emulatorWebFraction = fraction.clamp(0.12, 0.88);
    notifyListeners();
  }

  void setEmulatorMirrorMode(EmulatorMirrorMode mode) {
    emulatorMirrorMode = mode;
    notifyListeners();
  }

  void enableEmulatorRecordMode() {
    emulatorPanelVisible = true;
    emulatorMirrorMode = EmulatorMirrorMode.control;
    notifyListeners();
  }

  void addEmulatorTapStep(int x, int y) {
    _addEmulatorStep(
      MacroStep(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: MacroStepType.emulatorTap,
        x: x,
        y: y,
        label: 'Тап ($x, $y)',
      ),
    );
  }

  void addEmulatorSwipeStep(int x1, int y1, int x2, int y2, {int durationMs = 300}) {
    _addEmulatorStep(
      MacroStep(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: MacroStepType.emulatorSwipe,
        x: x1,
        y: y1,
        x2: x2,
        y2: y2,
        waitMs: durationMs,
        label: 'Свайп ($x1,$y1)→($x2,$y2)',
      ),
    );
  }

  void addEmulatorLongPressStep(int x, int y, {int durationMs = 800}) {
    _addEmulatorStep(
      MacroStep(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: MacroStepType.emulatorLongPress,
        x: x,
        y: y,
        waitMs: durationMs,
        label: 'Долгое ($x, $y)',
      ),
    );
  }

  void _addEmulatorStep(MacroStep step) {
    final draft = editingScenario;
    if (draft == null || !draft.isEmulator) return;
    addStepToEditing(step);
  }

  void editScenario(MacroScenario scenario) {
    editingScenario = scenario;
    notifyListeners();
  }

  void cancelScenarioEdit() {
    editingScenario = null;
    notifyListeners();
  }

  Future<void> saveEditingScenario({
    required String name,
    required int intervalMinutes,
    required bool enabled,
  }) async {
    final draft = editingScenario;
    if (draft == null) return;

    final scenario = draft.copyWith(
      name: name.trim().isEmpty ? 'Сценарий' : name.trim(),
      intervalMinutes: intervalMinutes.clamp(1, 10080),
      enabled: enabled,
    );

    final exists = storage.scenarios.any((s) => s.id == scenario.id);
    if (exists) {
      await storage.updateScenario(scenario);
    } else {
      await storage.addScenario(scenario);
    }

    editingScenario = null;
    _syncScenarioSchedules();
    notifyListeners();
  }

  void addStepToEditing(MacroStep step) {
    final draft = editingScenario;
    if (draft == null) return;
    editingScenario = draft.copyWith(steps: [...draft.steps, step]);
    notifyListeners();
  }

  void removeStepFromEditing(String stepId) {
    final draft = editingScenario;
    if (draft == null) return;
    editingScenario = draft.copyWith(
      steps: draft.steps.where((s) => s.id != stepId).toList(),
    );
    notifyListeners();
  }

  void moveStepUp(int index) {
    final draft = editingScenario;
    if (draft == null || index <= 0 || index >= draft.steps.length) return;
    final steps = [...draft.steps];
    final item = steps.removeAt(index);
    steps.insert(index - 1, item);
    editingScenario = draft.copyWith(steps: steps);
    notifyListeners();
  }

  void moveStepDown(int index) {
    final draft = editingScenario;
    if (draft == null || index < 0 || index >= draft.steps.length - 1) return;
    final steps = [...draft.steps];
    final item = steps.removeAt(index);
    steps.insert(index + 1, item);
    editingScenario = draft.copyWith(steps: steps);
    notifyListeners();
  }

  Future<void> runScenarioNow(MacroScenario scenario) async {
    await _executeScenario(scenario);
    await storage.updateScenario(scenario.copyWith(lastRunAt: DateTime.now()));
    notifyListeners();
  }

  Future<void> toggleScenario(MacroScenario scenario, bool enabled) async {
    final updated = scenario.copyWith(enabled: enabled);
    await storage.updateScenario(updated);
    _syncScenarioSchedules();
    notifyListeners();
  }

  Future<void> deleteScenario(MacroScenario scenario) async {
    if (editingScenario?.id == scenario.id) {
      editingScenario = null;
    }
    await storage.removeScenario(scenario.id);
    _syncScenarioSchedules();
    notifyListeners();
  }

  Future<MacroStep?> pickClickStep() async {
    final picked = await browser.pickElement();
    if (picked == null || picked['ok'] != true) return null;

    final selector = picked['selector']?.toString();
    if (selector != null && selector.isNotEmpty) {
      return MacroStep(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: MacroStepType.clickSelector,
        selector: selector,
        label: 'Клик: ${picked['text'] ?? selector}',
      );
    }

    return MacroStep(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: MacroStepType.clickCoordinates,
      x: picked['x'] as int? ?? 0,
      y: picked['y'] as int? ?? 0,
      label: 'Клик (${picked['x']}, ${picked['y']})',
    );
  }

  @override
  void dispose() {
    cancelAllActions();
    _actionWaitTicker?.cancel();
    _actionWaitTicker = null;
    _mapActivityTimer?.cancel();
    _dailyTemplateTimer?.cancel();
    _scheduler.dispose();
    _broadcastRunner.dispose();
    super.dispose();
  }
}
