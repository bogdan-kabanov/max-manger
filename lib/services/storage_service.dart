import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/account_map_state.dart';
import '../models/ai_chat_config.dart';
import '../models/automation_rule.dart';
import '../models/macro_scenario.dart';
import '../models/account_isolation.dart';
import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import '../models/mother_group_channel.dart';

class StorageService {
  StorageService._();

  static final StorageService instance = StorageService._();

  late Directory _rootDir;
  late File _dbFile;

  List<MaxAccount> accounts = [];
  List<AutomationRule> rules = [];
  List<MacroScenario> scenarios = [];
  List<AiChatConfig> aiConfigs = [];
  AccountMapState accountMap = const AccountMapState();
  final Map<String, List<MotherGroupChannel>> motherGroupsByAccountId = {};
  List<MaxChannelCatalogEntry> channelCatalog = [];

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    _rootDir = Directory('${support.path}${Platform.pathSeparator}max_desktop');
    await _rootDir.create(recursive: true);
    _dbFile = File('${_rootDir.path}${Platform.pathSeparator}data.json');
    await _load();
    await _migrateIsolationIfNeeded();
  }

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
      await save();
    }
  }

  Future<void> _load() async {
    if (!await _dbFile.exists()) {
      accounts = [];
      rules = [];
      scenarios = [];
      aiConfigs = [];
      accountMap = const AccountMapState();
      motherGroupsByAccountId.clear();
      channelCatalog = [];
      return;
    }

    final raw = await _dbFile.readAsString();
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
  }

  Future<void> saveAccountMap(AccountMapState map) async {
    accountMap = map;
    await save();
  }

  Future<void> save() async {
    final payload = {
      'accounts': accounts.map((a) => a.toJson()).toList(),
      'rules': rules.map((r) => r.toJson()).toList(),
      'scenarios': scenarios.map((s) => s.toJson()).toList(),
      'aiConfigs': aiConfigs.map((c) => c.toJson()).toList(),
      'accountMap': accountMap.toJson(),
      'motherGroups': {
        for (final entry in motherGroupsByAccountId.entries)
          entry.key: entry.value.map((g) => g.toJson()).toList(),
      },
      'channelCatalog': channelCatalog.map((e) => e.toJson()).toList(),
    };
    await _dbFile.writeAsString(jsonEncode(payload));
  }

  Future<MaxAccount> addAccount(String label) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final account = MaxAccount(
      id: id,
      label: label.trim().isEmpty ? 'Аккаунт ${accounts.length + 1}' : label.trim(),
      createdAt: DateTime.now(),
      isolation: ProfileFingerprint.generate(id),
    );
    accounts.add(account);
    await profileDirFor(account.id).create(recursive: true);
    await save();
    return account;
  }

  Future<MaxAccount> addAccountFromSms({
    required String phone,
    required String apiToken,
    String? label,
  }) async {
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
    await save();
    return account;
  }

  Future<MaxAccount> addAccountFromToken({
    required String apiToken,
    String? phone,
    String? label,
    int? viewerId,
    String? proxyServer,
    String? deviceId,
    AccountHealthStatus healthStatus = AccountHealthStatus.unknown,
    String? lastError,
  }) async {
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
    await save();
    return account;
  }

  Future<void> removeAccount(String id) async {
    accounts.removeWhere((a) => a.id == id);
    rules.removeWhere((r) => r.accountId == id);
    scenarios.removeWhere((s) => s.accountId == id);
    aiConfigs.removeWhere((c) => c.accountId == id);
    motherGroupsByAccountId.remove(id);
    await save();
    await _deleteProfileDir(id);
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

  Future<void> touchAccount(String id) async {
    final index = accounts.indexWhere((a) => a.id == id);
    if (index < 0) return;
    accounts[index] = accounts[index].copyWith(lastOpenedAt: DateTime.now());
    await save();
  }

  Future<void> updateAccount(MaxAccount account) async {
    final index = accounts.indexWhere((a) => a.id == account.id);
    if (index >= 0) {
      accounts[index] = account;
      await save();
    }
  }

  List<AutomationRule> rulesFor(String accountId) {
    return rules.where((r) => r.accountId == accountId).toList();
  }

  Future<AutomationRule> addRule(AutomationRule rule) async {
    rules.add(rule);
    await save();
    return rule;
  }

  Future<void> updateRule(AutomationRule rule) async {
    final index = rules.indexWhere((r) => r.id == rule.id);
    if (index >= 0) {
      rules[index] = rule;
      await save();
    }
  }

  Future<void> removeRule(String id) async {
    rules.removeWhere((r) => r.id == id);
    await save();
  }

  List<MacroScenario> scenariosFor(String accountId) {
    return scenarios.where((s) => s.accountId == accountId).toList();
  }

  Future<MacroScenario> addScenario(MacroScenario scenario) async {
    scenarios.add(scenario);
    await save();
    return scenario;
  }

  Future<void> updateScenario(MacroScenario scenario) async {
    final index = scenarios.indexWhere((s) => s.id == scenario.id);
    if (index >= 0) {
      scenarios[index] = scenario;
      await save();
    }
  }

  Future<void> removeScenario(String id) async {
    scenarios.removeWhere((s) => s.id == id);
    await save();
  }

  AiChatConfig aiConfigFor(String accountId) {
    return aiConfigs.firstWhere(
      (c) => c.accountId == accountId,
      orElse: () => AiChatConfig.defaults(accountId),
    );
  }

  Future<AiChatConfig> saveAiConfig(AiChatConfig config) async {
    final index = aiConfigs.indexWhere((c) => c.accountId == config.accountId);
    if (index >= 0) {
      aiConfigs[index] = config;
    } else {
      aiConfigs.add(config);
    }
    await save();
    return config;
  }

  List<MotherGroupChannel> motherGroupsFor(String accountId) =>
      List.unmodifiable(motherGroupsByAccountId[accountId] ?? const []);

  Future<void> saveMotherGroups(String accountId, List<MotherGroupChannel> groups) async {
    motherGroupsByAccountId[accountId] = List.of(groups);
    await save();
  }

  Future<void> mergeMotherGroups(String accountId, List<MotherGroupChannel> groups) async {
    final merged = MotherGroupChannel.mergeLists(motherGroupsFor(accountId), groups);
    await saveMotherGroups(accountId, merged);
  }

  List<MaxChannelCatalogEntry> get channelCatalogEntries => List.unmodifiable(channelCatalog);

  Future<void> saveChannelCatalog(List<MaxChannelCatalogEntry> entries) async {
    channelCatalog = List.of(entries);
    await save();
  }

  Future<void> mergeChannelCatalog(List<MaxChannelCatalogEntry> entries) async {
    channelCatalog = MaxChannelCatalogEntry.mergeLists(channelCatalog, entries);
    await save();
  }
}
