import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/account_map_state.dart';
import '../models/ai_chat_config.dart';
import '../models/automation_rule.dart';
import '../models/channel_funnel.dart';
import '../models/join_message_template.dart';
import '../models/macro_scenario.dart';
import '../models/account_isolation.dart';
import '../models/account_group_membership.dart';
import '../models/matka_template_binding.dart';
import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import '../models/mother_group_channel.dart';
import '../models/pipeline_journal_event.dart';
import '../models/rate_settings.dart';
import '../models/template_sent_record.dart';

class StorageService {
  StorageService._();

  static final StorageService instance = StorageService._();

  late Directory _rootDir;
  late File _dbFile;
  late File _lockFile;

  /// Serializes mutations inside one Flutter engine / isolate.
  Future<void>? _writeChain;

  List<MaxAccount> accounts = [];
  List<AutomationRule> rules = [];
  List<MacroScenario> scenarios = [];
  List<AiChatConfig> aiConfigs = [];
  AccountMapState accountMap = const AccountMapState();
  RateSettings rateSettings = RateSettings.defaults;
  final Map<String, List<MotherGroupChannel>> motherGroupsByAccountId = {};
  List<MaxChannelCatalogEntry> channelCatalog = [];
  /// Forever-growing set of chatIds/hashes already found by discovery.
  /// Survives catalog clear so next parse always skips known groups.
  final Set<String> seenDiscoverChatIds = {};
  final Set<String> seenDiscoverInviteHashes = {};
  List<String> discoverKeywords = [];
  List<ChannelFunnel> channelFunnels = [];
  final Map<String, AccountChannelPolicy> channelPoliciesByAccountId = {};
  List<JoinMessageTemplate> joinMessageTemplates = [];
  /// accountId → join message template id.
  final Map<String, String> joinTemplateByAccountId = {};
  /// Matka-level template bindings (onJoin / dailyAt).
  List<MatkaTemplateBinding> matkaTemplateBindings = [];
  /// Structured pipeline journal (newest first, capped).
  List<PipelineJournalEvent> pipelineJournal = [];
  static const int pipelineJournalCap = 400;
  /// accountId::chatId → membership record.
  final Map<String, AccountGroupMembership> accountGroupMemberships = {};
  /// accountId::chatId::templateId — successful template sends (skip / re-mail).
  final Set<String> templateSentKeys = {};
  /// Richer ledger with messageIds for delete + timestamps.
  final Map<String, TemplateSentRecord> templateSentRecords = {};

  static String templateSentKey({
    required String accountId,
    required String chatId,
    required String templateId,
  }) =>
      '$accountId::$chatId::$templateId';

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    _rootDir = Directory('${support.path}${Platform.pathSeparator}max_desktop');
    await _rootDir.create(recursive: true);
    _dbFile = File('${_rootDir.path}${Platform.pathSeparator}data.json');
    _lockFile = File('${_dbFile.path}.lock');
    await _load();
    await _migrateIsolationIfNeeded();
    if (_pendingJoinMigrationFlush) {
      await _mutate(() async {
        _pendingJoinMigrationFlush = false;
      });
    }
  }

  /// Re-read DB from disk (e.g. when a hidden sub-window is shown again).
  Future<void> reloadFromDisk() => _serialized(() async {
        await _withFileLock(() async {
          await _load();
        });
      });

  Directory profileDirFor(String accountId) {
    final dir = Directory(
      '${_rootDir.path}${Platform.pathSeparator}profiles${Platform.pathSeparator}$accountId',
    );
    return dir;
  }

  Future<void> _migrateIsolationIfNeeded() async {
    if (!await _dbFile.exists()) return;
    final raw = await _dbFile.readAsString();
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final rawAccounts = data['accounts'] as List<dynamic>? ?? [];
    final needsMigration = rawAccounts.any(
      (entry) => (entry as Map<String, dynamic>)['isolation'] == null,
    );
    if (needsMigration) {
      await _mutate(() async {});
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _writeChain;
    final gate = Completer<void>();
    _writeChain = gate.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<RandomAccessFile?> _acquireLock() async {
    for (var attempt = 0; attempt < 60; attempt++) {
      try {
        final raf = await _lockFile.open(mode: FileMode.write);
        await raf.lock(FileLock.exclusive);
        return raf;
      } catch (_) {
        await Future<void>.delayed(Duration(milliseconds: 40 + attempt * 15));
      }
    }
    return null;
  }

  Future<void> _withFileLock(Future<void> Function() body) async {
    final raf = await _acquireLock();
    try {
      await body();
    } finally {
      if (raf != null) {
        try {
          await raf.unlock();
        } catch (_) {}
        try {
          await raf.close();
        } catch (_) {}
      }
    }
  }

  /// Lock → reload disk → apply [mutator] → write full DB.
  /// Prevents stale secondary windows from wiping mother clusters / funnels.
  Future<T> _mutate<T>(Future<T> Function() mutator) {
    return _serialized(() async {
      late T result;
      await _withFileLock(() async {
        await _load();
        result = await mutator();
        await _writeUnlocked();
      });
      return result;
    });
  }

  Future<void> _load() async {
    if (!await _dbFile.exists()) {
      accounts = [];
      rules = [];
      scenarios = [];
      aiConfigs = [];
      accountMap = const AccountMapState();
      rateSettings = RateSettings.defaults;
      motherGroupsByAccountId.clear();
      channelCatalog = [];
      seenDiscoverChatIds.clear();
      seenDiscoverInviteHashes.clear();
      discoverKeywords = [];
      channelFunnels = [];
      channelPoliciesByAccountId.clear();
      joinMessageTemplates = [];
      joinTemplateByAccountId.clear();
      matkaTemplateBindings = [];
      pipelineJournal = [];
      accountGroupMemberships.clear();
      templateSentKeys.clear();
      templateSentRecords.clear();
      return;
    }

    final raw = await _dbFile.readAsString();
    if (raw.trim().isEmpty) return;

    final data = jsonDecode(raw) as Map<String, dynamic>;
    accounts = (data['accounts'] as List<dynamic>? ?? [])
        .map((e) => MaxAccount.fromJson(e as Map<String, dynamic>))
        .toList();
    rules = (data['rules'] as List<dynamic>? ?? [])
        .map((e) => AutomationRule.fromJson(e as Map<String, dynamic>))
        .toList();
    scenarios = (data['scenarios'] as List<dynamic>? ?? [])
        .map((e) => MacroScenario.fromJson(e as Map<String, dynamic>))
        .toList();
    aiConfigs = (data['aiConfigs'] as List<dynamic>? ?? [])
        .map((e) => AiChatConfig.fromJson(e as Map<String, dynamic>))
        .toList();
    accountMap = AccountMapState.fromJson(data['accountMap'] as Map<String, dynamic>?);
    rateSettings = RateSettings.fromJson(data['rateSettings'] as Map<String, dynamic>?);
    motherGroupsByAccountId.clear();
    final rawGroups = data['motherGroups'] as Map<String, dynamic>? ?? {};
    for (final entry in rawGroups.entries) {
      final list = entry.value;
      if (list is! List) continue;
      motherGroupsByAccountId[entry.key] = list
          .whereType<Map<String, dynamic>>()
          .map(MotherGroupChannel.fromJson)
          .where((g) => g.chatId.isNotEmpty)
          .toList();
    }
    channelCatalog = (data['channelCatalog'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(MaxChannelCatalogEntry.fromJson)
        .where((e) => e.chatId.isNotEmpty)
        .toList();
    seenDiscoverChatIds
      ..clear()
      ..addAll(
        (data['seenDiscoverChatIds'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty),
      );
    seenDiscoverInviteHashes
      ..clear()
      ..addAll(
        (data['seenDiscoverInviteHashes'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => MotherGroupChannel.isValidInviteHash(e)),
      );
    // Backfill from existing catalog / mother groups so old finds stay unique.
    _seedSeenFromKnownGroups();
    discoverKeywords = (data['discoverKeywords'] as List<dynamic>? ?? const [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    channelFunnels = (data['channelFunnels'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ChannelFunnel.fromJson)
        .toList();
    channelPoliciesByAccountId.clear();
    final rawPolicies = data['channelPolicies'] as List<dynamic>? ?? const [];
    for (final entry in rawPolicies.whereType<Map<String, dynamic>>()) {
      final policy = AccountChannelPolicy.fromJson(entry);
      if (policy.accountId.isEmpty) continue;
      channelPoliciesByAccountId[policy.accountId] = policy;
    }
    joinMessageTemplates = (data['joinMessageTemplates'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(JoinMessageTemplate.fromJson)
        .toList();
    joinTemplateByAccountId.clear();
    final rawJoinAssign = data['joinTemplateByAccountId'] as Map<String, dynamic>? ?? {};
    for (final entry in rawJoinAssign.entries) {
      final templateId = entry.value?.toString().trim() ?? '';
      if (entry.key.isEmpty || templateId.isEmpty) continue;
      joinTemplateByAccountId[entry.key] = templateId;
    }
    matkaTemplateBindings = (data['matkaTemplateBindings'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MatkaTemplateBinding.fromJson)
        .where((b) => b.motherAccountId.isNotEmpty && b.templateId.isNotEmpty)
        .toList();
    pipelineJournal = (data['pipelineJournal'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PipelineJournalEvent.fromJson)
        .where((e) => e.message.isNotEmpty)
        .toList();
    accountGroupMemberships.clear();
    final rawMemberships = data['accountGroupMemberships'] as List<dynamic>? ?? const [];
    for (final entry in rawMemberships.whereType<Map<String, dynamic>>()) {
      final m = AccountGroupMembership.fromJson(entry);
      if (m.accountId.isEmpty || m.chatId.isEmpty) continue;
      accountGroupMemberships[m.key] = m;
    }
    templateSentKeys
      ..clear()
      ..addAll(
        (data['templateSentKeys'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.split('::').length >= 3),
      );
    templateSentRecords.clear();
    final rawSent = data['templateSentRecords'] as List<dynamic>? ?? const [];
    for (final entry in rawSent.whereType<Map<String, dynamic>>()) {
      final r = TemplateSentRecord.fromJson(entry);
      if (r.accountId.isEmpty || r.chatId.isEmpty || r.templateId.isEmpty) continue;
      templateSentRecords[r.key] = r;
      templateSentKeys.add(r.key);
    }
    // Migrate bare keys into empty records.
    for (final key in templateSentKeys) {
      if (templateSentRecords.containsKey(key)) continue;
      final parts = key.split('::');
      if (parts.length < 3) continue;
      templateSentRecords[key] = TemplateSentRecord(
        accountId: parts[0],
        chatId: parts[1],
        templateId: parts.sublist(2).join('::'),
      );
    }
    final migrated = _migrateLegacyClusterPostJoin();
    _pendingJoinMigrationFlush = migrated;
  }

  bool _pendingJoinMigrationFlush = false;

  /// One-shot: move per-cluster post-join texts into shared templates.
  bool _migrateLegacyClusterPostJoin() {
    final clusters = accountMap.motherClusters;
    var templates = [...joinMessageTemplates];
    final assign = Map<String, String>.from(joinTemplateByAccountId);
    var changed = false;
    final nextClusters = <MotherCluster>[];

    for (final cluster in clusters) {
      final legacyMsgs = cluster.postJoinMessages
          .where((m) => m.text.trim().isNotEmpty)
          .toList();
      final hadLegacy = cluster.postJoinWriteEnabled || legacyMsgs.isNotEmpty;

      if (hadLegacy && legacyMsgs.isNotEmpty) {
        final childrenNeedAssign =
            cluster.childAccountIds.any((id) => !assign.containsKey(id));
        if (childrenNeedAssign) {
          final template = JoinMessageTemplate.create(
            name: 'После вступления · ${cluster.name}',
            messages: legacyMsgs,
            delayMs: cluster.postJoinDelayMs,
          );
          templates.add(template);
          for (final childId in cluster.childAccountIds) {
            assign.putIfAbsent(childId, () => template.id);
          }
          changed = true;
        }
      }

      if (hadLegacy) {
        changed = true;
        nextClusters.add(
          cluster.copyWith(
            postJoinWriteEnabled: false,
            postJoinMessages: const [],
            postJoinDelayMs: 5000,
          ),
        );
      } else {
        nextClusters.add(cluster);
      }
    }

    final validIds = templates.map((t) => t.id).toSet();
    final beforeAssign = assign.length;
    assign.removeWhere((_, id) => !validIds.contains(id));
    if (assign.length != beforeAssign) changed = true;

    if (!changed) return false;

    joinMessageTemplates = templates;
    joinTemplateByAccountId
      ..clear()
      ..addAll(assign);
    if (clusters.isNotEmpty) {
      accountMap = accountMap.copyWith(motherClusters: nextClusters);
    }
    return true;
  }

  void _seedSeenFromKnownGroups() {
    for (final entry in channelCatalog) {
      if (entry.chatId.isNotEmpty) seenDiscoverChatIds.add(entry.chatId);
      if (entry.hasInviteLink) seenDiscoverInviteHashes.add(entry.inviteHash!);
    }
    for (final groups in motherGroupsByAccountId.values) {
      for (final group in groups) {
        if (group.chatId.isNotEmpty) seenDiscoverChatIds.add(group.chatId);
        if (group.hasInviteLink) seenDiscoverInviteHashes.add(group.inviteHash!);
      }
    }
  }

  Future<void> _writeUnlocked() async {
    final payload = {
      'accounts': accounts.map((a) => a.toJson()).toList(),
      'rules': rules.map((r) => r.toJson()).toList(),
      'scenarios': scenarios.map((s) => s.toJson()).toList(),
      'aiConfigs': aiConfigs.map((c) => c.toJson()).toList(),
      'accountMap': accountMap.toJson(),
      'rateSettings': rateSettings.toJson(),
      'motherGroups': {
        for (final entry in motherGroupsByAccountId.entries)
          entry.key: entry.value.map((g) => g.toJson()).toList(),
      },
      'channelCatalog': channelCatalog.map((e) => e.toJson()).toList(),
      'seenDiscoverChatIds': seenDiscoverChatIds.toList()..sort(),
      'seenDiscoverInviteHashes': seenDiscoverInviteHashes.toList()..sort(),
      'discoverKeywords': discoverKeywords,
      'channelFunnels': channelFunnels.map((f) => f.toJson()).toList(),
      'channelPolicies': channelPoliciesByAccountId.values.map((p) => p.toJson()).toList(),
      'joinMessageTemplates': joinMessageTemplates.map((t) => t.toJson()).toList(),
      'joinTemplateByAccountId': joinTemplateByAccountId,
      'matkaTemplateBindings': matkaTemplateBindings.map((b) => b.toJson()).toList(),
      'pipelineJournal': pipelineJournal.map((e) => e.toJson()).toList(),
      'accountGroupMemberships':
          accountGroupMemberships.values.map((m) => m.toJson()).toList(),
      'templateSentKeys': templateSentKeys.toList()..sort(),
      'templateSentRecords':
          templateSentRecords.values.map((r) => r.toJson()).toList(),
    };
    final tmp = File('${_dbFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload));
    if (await _dbFile.exists()) {
      try {
        await tmp.rename(_dbFile.path);
        return;
      } catch (_) {
        // Windows may block rename over existing file — fall through.
      }
    }
    await _dbFile.writeAsString(jsonEncode(payload));
    if (await tmp.exists()) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }

  Future<void> saveAccountMap(AccountMapState map) => _mutate(() async {
        accountMap = map;
      });

  Future<void> saveRateSettings(RateSettings settings) => _mutate(() async {
        rateSettings = settings;
      });

  Future<void> saveChannelFunnels(List<ChannelFunnel> funnels) => _mutate(() async {
        channelFunnels = funnels;
      });

  Future<void> saveChannelPolicies(Map<String, AccountChannelPolicy> policies) =>
      _mutate(() async {
        channelPoliciesByAccountId
          ..clear()
          ..addAll(policies);
      });

  Future<void> saveJoinMessageTemplates(List<JoinMessageTemplate> templates) =>
      _mutate(() async {
        joinMessageTemplates = templates;
      });

  Future<void> saveJoinTemplateAssignments(Map<String, String> assignments) =>
      _mutate(() async {
        joinTemplateByAccountId
          ..clear()
          ..addAll(assignments);
      });

  List<AccountGroupMembership> membershipsFor(String accountId) {
    return accountGroupMemberships.values
        .where((m) => m.accountId == accountId)
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  Set<String> membershipChatIdsFor(String accountId) => {
        for (final m in accountGroupMemberships.values)
          if (m.accountId == accountId) m.chatId,
      };

  Future<void> upsertMemberships(Iterable<AccountGroupMembership> items) =>
      _mutate(() async {
        for (final item in items) {
          if (item.accountId.isEmpty || item.chatId.isEmpty) continue;
          final prev = accountGroupMemberships[item.key];
          accountGroupMemberships[item.key] = AccountGroupMembership(
            accountId: item.accountId,
            chatId: item.chatId,
            title: item.title.trim().isNotEmpty
                ? item.title
                : (prev?.title ?? ''),
            joinedAt: item.joinedAt ?? prev?.joinedAt ?? DateTime.now(),
            lastVerifiedAt: item.lastVerifiedAt ?? prev?.lastVerifiedAt,
          );
        }
      });

  Future<void> removeMemberships({
    String? accountId,
    Iterable<String>? chatIds,
  }) =>
      _mutate(() async {
        final chats = chatIds?.map((e) => e.toString()).toSet();
        accountGroupMemberships.removeWhere((_, m) {
          if (accountId != null && m.accountId != accountId) return false;
          if (chats != null && !chats.contains(m.chatId)) return false;
          return accountId != null || chats != null;
        });
      });

  /// Replace expected memberships for [accountId] with what list-groups returned
  /// among [expectedChatIds] (or all listed groups if expected is null).
  Future<void> syncMembershipsFromListedGroups({
    required String accountId,
    required List<MotherGroupChannel> listed,
    Set<String>? expectedChatIds,
  }) =>
      _mutate(() async {
        final now = DateTime.now();
        final listedById = {
          for (final g in listed)
            if (g.chatId.isNotEmpty) g.chatId: g,
        };
        final expected = expectedChatIds ?? listedById.keys.toSet();

        // Drop expected chats that are no longer present.
        accountGroupMemberships.removeWhere(
          (_, m) => m.accountId == accountId && expected.contains(m.chatId) && !listedById.containsKey(m.chatId),
        );

        for (final chatId in expected) {
          final g = listedById[chatId];
          if (g == null) continue;
          final key = '$accountId::$chatId';
          final prev = accountGroupMemberships[key];
          accountGroupMemberships[key] = AccountGroupMembership(
            accountId: accountId,
            chatId: chatId,
            title: g.title.isNotEmpty ? g.title : (prev?.title ?? ''),
            joinedAt: prev?.joinedAt ?? now,
            lastVerifiedAt: now,
          );
        }
      });

  AccountChannelPolicy channelPolicyFor(String accountId) {
    return channelPoliciesByAccountId[accountId] ??
        AccountChannelPolicy(accountId: accountId);
  }

  JoinMessageTemplate? joinTemplateForAccount(String accountId) {
    final id = joinTemplateByAccountId[accountId];
    if (id == null) return null;
    for (final t in joinMessageTemplates) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<MaxAccount> addAccount(String label) => _mutate(() async {
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        final account = MaxAccount(
          id: id,
          label: label.trim().isEmpty ? 'Аккаунт ${accounts.length + 1}' : label.trim(),
          createdAt: DateTime.now(),
          isolation: ProfileFingerprint.generate(id),
        );
        accounts.add(account);
        await profileDirFor(account.id).create(recursive: true);
        return account;
      });

  Future<MaxAccount> addAccountFromSms({
    required String phone,
    required String apiToken,
    String? label,
  }) =>
      _mutate(() async {
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        final account = MaxAccount(
          id: id,
          label: label?.trim().isNotEmpty == true ? label!.trim() : phone,
          createdAt: DateTime.now(),
          isolation: ProfileFingerprint.generate(id),
          phone: phone,
          apiToken: apiToken,
          authMethod: MaxAuthMethod.sms,
        );
        accounts.add(account);
        await profileDirFor(account.id).create(recursive: true);
        return account;
      });

  Future<MaxAccount> addAccountFromToken({
    required String apiToken,
    String? phone,
    String? label,
    int? viewerId,
    String? proxyServer,
    String? deviceId,
    AccountHealthStatus healthStatus = AccountHealthStatus.unknown,
    String? lastError,
  }) =>
      _mutate(() async {
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        var isolation = ProfileFingerprint.generate(id);
        final proxy = proxyServer?.trim();
        if (proxy != null && proxy.isNotEmpty) {
          isolation = isolation.copyWith(proxyServer: proxy);
        }
        final device = deviceId?.trim();
        if (device != null && device.isNotEmpty) {
          isolation = isolation.copyWith(deviceId: device);
        }
        final checked = healthStatus != AccountHealthStatus.unknown;
        final account = MaxAccount(
          id: id,
          label: label?.trim().isNotEmpty == true ? label!.trim() : (phone ?? 'Аккаунт'),
          createdAt: DateTime.now(),
          isolation: isolation,
          phone: phone,
          apiToken: apiToken,
          viewerId: viewerId,
          authMethod: MaxAuthMethod.token,
          healthStatus: healthStatus,
          lastError: lastError,
          lastCheckedAt: checked ? DateTime.now() : null,
        );
        accounts.add(account);
        await profileDirFor(account.id).create(recursive: true);
        return account;
      });

  Future<void> removeAccount(String id) async {
    await _mutate(() async {
      accounts.removeWhere((a) => a.id == id);
      rules.removeWhere((r) => r.accountId == id);
      scenarios.removeWhere((s) => s.accountId == id);
      aiConfigs.removeWhere((c) => c.accountId == id);
      motherGroupsByAccountId.remove(id);
      channelPoliciesByAccountId.remove(id);
      joinTemplateByAccountId.remove(id);
      matkaTemplateBindings =
          matkaTemplateBindings.where((b) => b.motherAccountId != id).toList();
      channelCatalog = [
        for (final e in channelCatalog)
          if (e.assignedMotherAccountId == id)
            e.copyWith(clearAssignment: true)
          else
            e,
      ];
      accountGroupMemberships.removeWhere((_, m) => m.accountId == id);
      templateSentKeys.removeWhere((k) => k.startsWith('$id::'));
      templateSentRecords.removeWhere((k, _) => k.startsWith('$id::'));
    });
    await _deleteProfileDir(id);
  }

  bool hasTemplateSent({
    required String accountId,
    required String chatId,
    required String templateId,
  }) {
    final a = accountId.trim();
    final c = chatId.trim();
    final t = templateId.trim();
    if (a.isEmpty || c.isEmpty || t.isEmpty) return false;
    final key = templateSentKey(accountId: a, chatId: c, templateId: t);
    return templateSentRecords.containsKey(key) || templateSentKeys.contains(key);
  }

  TemplateSentRecord? templateSentRecord({
    required String accountId,
    required String chatId,
    required String templateId,
  }) {
    final key = templateSentKey(
      accountId: accountId.trim(),
      chatId: chatId.trim(),
      templateId: templateId.trim(),
    );
    return templateSentRecords[key];
  }

  List<TemplateSentRecord> templateSentRecordsFor({
    String? templateId,
    String? accountId,
  }) {
    final t = templateId?.trim();
    final a = accountId?.trim();
    return [
      for (final r in templateSentRecords.values)
        if ((t == null || t.isEmpty || r.templateId == t) &&
            (a == null || a.isEmpty || r.accountId == a))
          r,
    ];
  }

  Future<void> markTemplateSentMany({
    required String accountId,
    required Iterable<String> chatIds,
    required String templateId,
    Map<String, List<String>> messageIdsByChatId = const {},
    Map<String, String> titleByChatId = const {},
  }) =>
      _mutate(() async {
        final a = accountId.trim();
        final t = templateId.trim();
        if (a.isEmpty || t.isEmpty) return;
        final now = DateTime.now();
        for (final raw in chatIds) {
          final c = raw.trim();
          if (c.isEmpty) continue;
          final key = templateSentKey(accountId: a, chatId: c, templateId: t);
          templateSentKeys.add(key);
          final prev = templateSentRecords[key];
          final ids = messageIdsByChatId[c] ?? const <String>[];
          final mergedIds = <String>{
            ...?prev?.messageIds,
            ...ids,
          }.toList();
          templateSentRecords[key] = TemplateSentRecord(
            accountId: a,
            chatId: c,
            templateId: t,
            title: titleByChatId[c] ?? prev?.title ?? '',
            messageIds: mergedIds,
            sentAt: now,
          );
        }
      });

  Future<void> clearTemplateSentHistory({
    String? templateId,
    String? accountId,
    Iterable<String>? chatIds,
  }) =>
      _mutate(() async {
        final t = templateId?.trim();
        final a = accountId?.trim();
        final chats = chatIds?.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
        if ((t == null || t.isEmpty) &&
            (a == null || a.isEmpty) &&
            (chats == null || chats.isEmpty)) {
          templateSentKeys.clear();
          templateSentRecords.clear();
          return;
        }
        templateSentKeys.removeWhere((key) {
          final parts = key.split('::');
          if (parts.length < 3) return true;
          final keyAccount = parts[0];
          final keyChat = parts[1];
          final keyTemplate = parts.sublist(2).join('::');
          if (a != null && a.isNotEmpty && keyAccount != a) return false;
          if (t != null && t.isNotEmpty && keyTemplate != t) return false;
          if (chats != null && chats.isNotEmpty && !chats.contains(keyChat)) {
            return false;
          }
          return true;
        });
        templateSentRecords.removeWhere((key, r) {
          if (a != null && a.isNotEmpty && r.accountId != a) return false;
          if (t != null && t.isNotEmpty && r.templateId != t) return false;
          if (chats != null && chats.isNotEmpty && !chats.contains(r.chatId)) {
            return false;
          }
          return true;
        });
      });

  int countTemplateSent({String? templateId, String? accountId}) {
    final t = templateId?.trim();
    final a = accountId?.trim();
    var n = 0;
    for (final r in templateSentRecords.values) {
      if (a != null && a.isNotEmpty && r.accountId != a) continue;
      if (t != null && t.isNotEmpty && r.templateId != t) continue;
      n += 1;
    }
    if (n > 0) return n;
    for (final key in templateSentKeys) {
      final parts = key.split('::');
      if (parts.length < 3) continue;
      final keyAccount = parts[0];
      final keyTemplate = parts.sublist(2).join('::');
      if (a != null && a.isNotEmpty && keyAccount != a) continue;
      if (t != null && t.isNotEmpty && keyTemplate != t) continue;
      n += 1;
    }
    return n;
  }

  Future<void> _deleteProfileDir(String id) async {
    final profile = profileDirFor(id);
    if (!await profile.exists()) return;

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await profile.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 2) return;
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
  }

  Future<void> touchAccount(String id) => _mutate(() async {
        final index = accounts.indexWhere((a) => a.id == id);
        if (index < 0) return;
        accounts[index] = accounts[index].copyWith(lastOpenedAt: DateTime.now());
      });

  Future<void> updateAccount(MaxAccount account) => _mutate(() async {
        final index = accounts.indexWhere((a) => a.id == account.id);
        if (index >= 0) {
          accounts[index] = account;
        }
      });

  List<AutomationRule> rulesFor(String accountId) {
    return rules.where((r) => r.accountId == accountId).toList();
  }

  Future<AutomationRule> addRule(AutomationRule rule) => _mutate(() async {
        rules.add(rule);
        return rule;
      });

  Future<void> updateRule(AutomationRule rule) => _mutate(() async {
        final index = rules.indexWhere((r) => r.id == rule.id);
        if (index >= 0) {
          rules[index] = rule;
        }
      });

  Future<void> removeRule(String id) => _mutate(() async {
        rules.removeWhere((r) => r.id == id);
      });

  List<MacroScenario> scenariosFor(String accountId) {
    return scenarios.where((s) => s.accountId == accountId).toList();
  }

  Future<MacroScenario> addScenario(MacroScenario scenario) => _mutate(() async {
        scenarios.add(scenario);
        return scenario;
      });

  Future<void> updateScenario(MacroScenario scenario) => _mutate(() async {
        final index = scenarios.indexWhere((s) => s.id == scenario.id);
        if (index >= 0) {
          scenarios[index] = scenario;
        }
      });

  Future<void> removeScenario(String id) => _mutate(() async {
        scenarios.removeWhere((s) => s.id == id);
      });

  AiChatConfig aiConfigFor(String accountId) {
    return aiConfigs.firstWhere(
      (c) => c.accountId == accountId,
      orElse: () => AiChatConfig.defaults(accountId),
    );
  }

  Future<AiChatConfig> saveAiConfig(AiChatConfig config) => _mutate(() async {
        final index = aiConfigs.indexWhere((c) => c.accountId == config.accountId);
        if (index >= 0) {
          aiConfigs[index] = config;
        } else {
          aiConfigs.add(config);
        }
        return config;
      });

  List<MotherGroupChannel> motherGroupsFor(String accountId) =>
      List.unmodifiable(motherGroupsByAccountId[accountId] ?? const []);

  Future<void> saveMotherGroups(String accountId, List<MotherGroupChannel> groups) =>
      _mutate(() async {
        motherGroupsByAccountId[accountId] = List.of(groups);
      });

  Future<void> mergeMotherGroups(String accountId, List<MotherGroupChannel> groups) =>
      _mutate(() async {
        final merged = MotherGroupChannel.mergeLists(motherGroupsFor(accountId), groups);
        motherGroupsByAccountId[accountId] = List.of(merged);
        _rememberDiscoveredGroupsInMemory(groups);
      });

  Future<void> removeMotherGroups(String accountId, Iterable<String> chatIds) async {
    final remove = chatIds.map((id) => id.toString()).toSet();
    if (remove.isEmpty) return;
    await _mutate(() async {
      final next = motherGroupsFor(accountId).where((g) => !remove.contains(g.chatId)).toList();
      motherGroupsByAccountId[accountId] = List.of(next);
    });
  }

  List<MaxChannelCatalogEntry> get channelCatalogEntries => List.unmodifiable(channelCatalog);

  int get seenDiscoverCount =>
      seenDiscoverChatIds.length > seenDiscoverInviteHashes.length
          ? seenDiscoverChatIds.length
          : seenDiscoverInviteHashes.length;

  List<String> get discoverExcludeChatIds =>
      List.unmodifiable(seenDiscoverChatIds.toList()..sort());

  List<String> get discoverExcludeHashes =>
      List.unmodifiable(seenDiscoverInviteHashes.toList()..sort());

  Future<void> saveChannelCatalog(List<MaxChannelCatalogEntry> entries) => _mutate(() async {
        channelCatalog = List.of(entries);
      });

  Future<void> mergeChannelCatalog(List<MaxChannelCatalogEntry> entries) => _mutate(() async {
        channelCatalog = MaxChannelCatalogEntry.mergeLists(channelCatalog, entries);
        _rememberDiscoveredChannelsInMemory(entries);
      });

  /// Persist discovered groups forever so the next parse skips them.
  Future<bool> rememberDiscoveredChannels(Iterable<MaxChannelCatalogEntry> entries) =>
      _mutate(() async {
        final changed = _rememberDiscoveredChannelsInMemory(entries);
        return changed;
      });

  bool _rememberDiscoveredChannelsInMemory(Iterable<MaxChannelCatalogEntry> entries) {
    var changed = false;
    for (final entry in entries) {
      final chatId = entry.chatId.trim();
      if (chatId.isNotEmpty && seenDiscoverChatIds.add(chatId)) changed = true;
      if (entry.hasInviteLink && seenDiscoverInviteHashes.add(entry.inviteHash!.trim())) {
        changed = true;
      }
    }
    return changed;
  }

  Future<bool> rememberDiscoveredGroups(Iterable<MotherGroupChannel> groups) =>
      _mutate(() async {
        final changed = _rememberDiscoveredGroupsInMemory(groups);
        return changed;
      });

  bool _rememberDiscoveredGroupsInMemory(Iterable<MotherGroupChannel> groups) {
    var changed = false;
    for (final group in groups) {
      final chatId = group.chatId.trim();
      if (chatId.isNotEmpty && seenDiscoverChatIds.add(chatId)) changed = true;
      if (group.hasInviteLink && seenDiscoverInviteHashes.add(group.inviteHash!.trim())) {
        changed = true;
      }
    }
    return changed;
  }

  Future<void> saveDiscoverKeywords(List<String> keywords) => _mutate(() async {
        discoverKeywords = [
          for (final raw in keywords)
            if (raw.trim().isNotEmpty) raw.trim(),
        ];
      });

  Future<void> saveMatkaTemplateBindings(List<MatkaTemplateBinding> bindings) =>
      _mutate(() async {
        matkaTemplateBindings = List.of(bindings);
      });

  Future<void> appendPipelineJournal(PipelineJournalEvent event) => _mutate(() async {
        pipelineJournal = [event, ...pipelineJournal].take(pipelineJournalCap).toList();
      });

  Future<void> clearPipelineJournal() => _mutate(() async {
        pipelineJournal = [];
      });

  Future<void> assignCatalogGroupsToMother({
    required Iterable<String> chatIds,
    required String? motherAccountId,
  }) =>
      _mutate(() async {
        final ids = chatIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
        if (ids.isEmpty) return;
        final mother =
            motherAccountId != null && motherAccountId.trim().isNotEmpty ? motherAccountId.trim() : null;
        channelCatalog = [
          for (final e in channelCatalog)
            if (ids.contains(e.chatId))
              e.copyWith(
                assignedMotherAccountId: mother,
                clearAssignment: mother == null,
              )
            else
              e,
        ];
      });

  List<MaxChannelCatalogEntry> catalogForMother(String motherAccountId) =>
      channelCatalog
          .where((e) => e.assignedMotherAccountId == motherAccountId)
          .toList(growable: false);

  List<MaxChannelCatalogEntry> get freeCatalogEntries =>
      channelCatalog.where((e) => !e.isAssigned).toList(growable: false);
}
