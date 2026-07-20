import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/account_map_state.dart';
import '../models/account_isolation.dart';
import '../models/ai_chat_config.dart';
import '../models/automation_rule.dart';
import '../models/emulator_profile.dart';
import '../models/macro_scenario.dart';
import '../models/macro_step.dart';
import '../models/max_account.dart';
import '../services/browser_session_manager.dart';
import '../services/ai_chat_service.dart';
import '../services/emulator_macro_runner.dart';
import '../services/max_auth_service.dart';
import '../services/max_ws_service.dart';
import '../models/map_workflow.dart';
import '../services/broadcast_workflow_runner.dart';
import '../services/max_mother_service.dart';
import '../services/scenario_scheduler.dart';
import '../services/storage_service.dart';

enum EmulatorMirrorMode { control, record, view }

extension EmulatorMirrorModeX on EmulatorMirrorMode {
  bool get canInteract => this != EmulatorMirrorMode.view;
}

class AppState extends ChangeNotifier {
  AppState(this.browser) {
    _scheduler = ScenarioScheduler();
  }

  final BrowserSessionManager browser;
  final MaxWsService maxWs = MaxWsService();
  final StorageService storage = StorageService.instance;
  late final ScenarioScheduler _scheduler;
  final BroadcastWorkflowRunner _broadcastRunner = BroadcastWorkflowRunner();

  MaxAccount? selectedAccount;
  String? selectedWorkflowNodeId;
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
  List<MotherCluster> get motherClusters => accountMap.motherClusters;
  String? get motherAccountId => accountMap.motherAccountId;
  Set<String> get childAccountIds => accountMap.childAccountIds;
  bool isMotherAccount(String accountId) => accountMap.isMotherAccount(accountId);
  bool isChildAccount(String accountId) => accountMap.isChildAccount(accountId);
  List<MapWorkflowNode> get workflowNodes => accountMap.workflowNodes;
  List<WorkflowMapEdge> get workflowEdges => accountMap.workflowEdges;

  Future<void> _persistAccountMap(AccountMapState map) async {
    await storage.saveAccountMap(map);
    _syncBroadcastSchedules();
    notifyListeners();
  }

  void _syncBroadcastSchedules() {
    _broadcastRunner.syncSchedules(
      nodes: accountMap.workflowNodes,
      edges: accountMap.workflowEdges,
      accounts: accounts,
      onLog: (msg, {String level = 'info'}) => browser.logMessage(msg, level: level),
    );
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

  /// Чаты/группы MAX, доступные для выбора у аккаунта (из кэша матки + WS).
  List<String> availableChatsForAccount(String accountId) {
    final names = <String>{};
    for (final group in storage.motherGroupsFor(accountId)) {
      final title = group.title.trim();
      if (title.isNotEmpty) names.add(title);
    }
    if (selectedAccount?.id == accountId && maxWs.isConnected) {
      for (final title in maxWs.chatTitles.values) {
        final t = title.trim();
        if (t.isNotEmpty) names.add(t);
      }
    }
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Загружает список групп/чатов аккаунта из MAX API.
  Future<void> refreshAccountChatCatalog(String accountId) async {
    final account = accountById(accountId);
    if (account == null || !account.hasApiSession) {
      throw StateError('У аккаунта нет API-токена');
    }
    browser.logMessage('Загрузка групп MAX для «${account.label}»…');
    final result = await MaxMotherService.listMotherGroups(
      token: account.apiToken!,
      scanMessages: false,
      proxy: account.isolation.proxyServer,
      onProgress: (line) => browser.logMessage(line),
    );
    if (!result.ok) {
      throw StateError(result.message);
    }
    await storage.mergeMotherGroups(accountId, result.groups);
    browser.logMessage('Групп в каталоге: ${result.groups.length}');

    if (selectedAccount?.id == accountId) {
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
    await _broadcastRunner.runBroadcast(
      node: node,
      edges: accountMap.workflowEdges,
      accounts: accounts,
      onLog: (msg, {String level = 'info'}) => browser.logMessage(msg, level: level),
    );
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
      name: name ?? 'Матка $index',
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

  /// Updates one cluster's mother/children without touching other clusters.
  Future<void> setMotherClusterRelations({
    required String clusterId,
    String? motherId,
    Set<String>? childIds,
    bool clearMother = false,
  }) async {
    final existing = accountMap.clusterById(clusterId);
    if (existing == null) return;
    final occupied = accountMap.occupiedAccountIds(exceptClusterId: clusterId);
    final nextMother = clearMother ? null : (motherId ?? existing.motherAccountId);
    if (nextMother != null && occupied.contains(nextMother)) {
      return;
    }
    final requestedChildren = childIds ?? existing.childAccountIds;
    final nextChildren = {
      for (final id in requestedChildren)
        if (id != nextMother && !occupied.contains(id)) id,
    };
    await updateMotherCluster(
      existing.copyWith(
        motherAccountId: nextMother,
        childAccountIds: nextChildren,
        clearMother: clearMother,
      ),
    );
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
  }) async {
    final account = await storage.addAccountFromToken(
      apiToken: apiToken,
      phone: phone,
      label: label,
      viewerId: viewerId,
      proxyServer: proxyServer,
      deviceId: deviceId,
    );
    notifyListeners();
    if (openBrowser) {
      await selectAccountById(account.id, openBrowser: true);
    }
    return account;
  }

  /// Bulk create from parsed token files. Does not open a browser per account.
  Future<List<MaxAccount>> addAccountsFromTokenImports({
    required List<({String apiToken, String? label, int? viewerId, String? deviceId})> items,
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
        viewerId: item.viewerId,
        proxyServer: proxyServer,
        deviceId: item.deviceId,
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
    if (!result.ok || result.profileId == null) return null;

    final updated = account.copyWith(
      viewerId: result.profileId,
      phone: result.profilePhone ?? account.phone,
      authMethod: MaxAuthMethod.token,
    );
    await storage.updateAccount(updated);
    if (selectedAccount?.id == account.id) {
      selectedAccount = updated;
    }
    notifyListeners();
    return result.profileId;
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
    await browser.openAccount(account);
    await _syncAiWs();
    _syncScenarioSchedules();
    notifyListeners();
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

  Future<void> _executeScenario(MacroScenario scenario) async {
    if (scenario.isEmulator) {
      MaxAccount? account;
      for (final a in storage.accounts) {
        if (a.id == scenario.accountId) {
          account = a;
          break;
        }
      }
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

    if (browser.activeAccount?.id != scenario.accountId) return;
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
    _mapActivityTimer?.cancel();
    _scheduler.dispose();
    _broadcastRunner.dispose();
    super.dispose();
  }
}
