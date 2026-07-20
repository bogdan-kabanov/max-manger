import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/account_map_state.dart';
import '../models/max_account.dart';
import '../models/mother_group_channel.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';
import '../services/max_mother_service.dart';
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

  @override
  void initState() {
    super.initState();
    _delayController = TextEditingController(text: '2500');
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

  void _log(String msg, {String level = 'info'}) {
    context.read<BrowserSessionManager>().logMessage('[Матка] $msg', level: level);
    _emitMapActivity(msg);
  }

  void _syncMapRelations() {
    context.read<AppState>().setMotherRelations(
          motherId: _motherId,
          childIds: _childIds,
        );
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
      _failPrepare('Снимите каналы и вставьте ссылку — или выберите каналы матки');
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
    final urls = selectedGroups.isEmpty && hasManualLink
        ? manualUrls
        : JoinLinkParser.toUrls(childHashes);

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

  Future<void> _afterRun(MotherJoinResult result, String motherId) async {
    if (result.groups.isNotEmpty) {
      await _persistGroups(motherId, result.groups);
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
    _log('Подготовка…');
    final prepared = await _prepareRun(mode);
    if (prepared == null) return;

    final mother = _mother(state)!;
    final delay = int.tryParse(_delayController.text) ?? 2500;

    if (state.browser.activeAccount?.id == mother.id) {
      _log('⚠ Матка открыта в MAX — закрываем браузер, иначе API-сессия оборвётся');
      await state.browser.releaseWebview();
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    setState(() => _running = true);

    final modeLabel = switch (mode) {
      _MotherMode.full => 'полный цикл',
      _MotherMode.motherJoin => 'только вступление матки',
      _MotherMode.inviteOnly => 'приглашение по ID',
      _MotherMode.forwardOnly => 'пересылка ссылок',
      _MotherMode.forwardAndJoin => 'переслать и вступить',
      _MotherMode.childrenJoinOnly => 'дочерние по ссылкам',
    };
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
          onProgress: _log,
        );
        await _afterRun(result, mother.id);
      } else if (mode == _MotherMode.inviteOnly) {
        await state.ensureViewerId(mother);
        final m = state.accountById(mother.id)!;
        final inviteIds = <int>[];
        for (final child in prepared.children) {
          final id = await state.ensureViewerId(child);
          if (id != null) inviteIds.add(id);
        }
        if (inviteIds.isEmpty) {
          _failPrepare('Нет viewerId у дочерних — используйте «Переслать и вступить»');
          return;
        }
        result = await MaxMotherService.inviteChildren(
          motherToken: m.apiToken!,
          links: prepared.manualUrls,
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          inviteUserIds: inviteIds,
          delayMs: delay,
          proxy: proxy,
          onProgress: _log,
        );
        await _afterRun(result, mother.id);
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
          return;
        }
        result = await MaxMotherService.forwardLinks(
          motherToken: mForward.apiToken!,
          links: prepared.inviteChatIds.isEmpty ? prepared.manualUrls : const [],
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          forwardUserIds: forwardIds,
          delayMs: delay,
          proxy: proxy,
          onProgress: _log,
        );
        await _afterRun(result, mother.id);
      } else if (mode == _MotherMode.forwardAndJoin) {
        await state.ensureViewerId(mother);
        final mFj = state.accountById(mother.id)!;
        final targets = <Map<String, dynamic>>[];
        for (final child in prepared.children) {
          final id = await state.ensureViewerId(child);
          final fresh = state.accountById(child.id)!;
          if (id != null && fresh.hasApiSession) {
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
          return;
        }
        result = await MaxMotherService.forwardAndJoin(
          motherToken: mFj.apiToken!,
          links: prepared.inviteChatIds.isEmpty ? prepared.manualUrls : const [],
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          childTargets: targets,
          delayMs: delay,
          proxy: proxy,
          onProgress: _log,
        );
        await _afterRun(result, mother.id);
      } else if (mode == _MotherMode.childrenJoinOnly) {
        final tokens = <String>[];
        final childProxies = <String?>[];
        for (final child in prepared.children) {
          await state.ensureViewerId(child);
          final fresh = state.accountById(child.id)!;
          if (fresh.hasApiSession) {
            tokens.add(fresh.apiToken!);
            final p = fresh.isolation.proxyServer?.trim();
            childProxies.add((p != null && p.isNotEmpty) ? p : proxy);
          }
        }
        if (tokens.isEmpty) {
          _failPrepare('Нет токенов у дочерних аккаунтов');
          return;
        }
        result = await MaxMotherService.childrenJoin(
          childTokens: tokens,
          links: prepared.inviteChatIds.isEmpty ? prepared.manualUrls : const [],
          groups: prepared.groups,
          chatIds: prepared.inviteChatIds,
          motherToken: state.accountById(mother.id)?.apiToken,
          delayMs: delay,
          proxy: proxy,
          childProxies: childProxies,
          onProgress: _log,
        );
        await _afterRun(result, mother.id);
      } else {
        await state.ensureViewerId(mother);
        final freshMother = state.accountById(mother.id)!;
        final inviteIds = <int>[];
        final forwardIds = <int>[];
        final childTokens = <String>[];
        final childTargets = <Map<String, dynamic>>[];
        for (final child in prepared.children) {
          final id = await state.ensureViewerId(child);
          final fresh = state.accountById(child.id)!;
          if (id != null) {
            inviteIds.add(id);
            forwardIds.add(id);
          }
          if (fresh.hasApiSession) {
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
          onProgress: _log,
        );
        await _afterRun(result, mother.id);
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

      final webJoinUrls = prepared.inviteChatIds.isEmpty ? prepared.manualUrls : prepared.urls;
      final shouldOpenWebConfirm = webJoinUrls.isNotEmpty &&
          prepared.children.isNotEmpty &&
          (result.forwarded > 0 ||
              mode == _MotherMode.childrenJoinOnly ||
              mode == _MotherMode.forwardOnly ||
              mode == _MotherMode.forwardAndJoin);
      if (shouldOpenWebConfirm) {
        await _confirmJoinLinksInChildBrowser(urls: webJoinUrls, children: prepared.children);
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _run() => _runMode(_MotherMode.full);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final accounts = state.accounts;
    final selected = state.selectedAccount;

    if (_motherId == null || !accounts.any((a) => a.id == _motherId)) {
      _motherId = state.motherAccountId ?? selected?.id ?? (accounts.isNotEmpty ? accounts.first.id : null);
    }
    if (_childIds.isEmpty && state.childAccountIds.isNotEmpty) {
      _childIds.addAll(state.childAccountIds);
    }

    final otherAccounts = accounts.where((a) => a.id != _motherId).toList();
    if (_childIds.isEmpty && otherAccounts.length == 1 && otherAccounts.first.hasApiSession) {
      _childIds.add(otherAccounts.first.id);
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncMapRelations());
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
          'Матка вступает в группы и добавляет выбранные аккаунты.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: accounts.any((a) => a.id == _motherId) ? _motherId : null,
          decoration: const InputDecoration(
            labelText: 'Аккаунт-матка',
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          items: [
            for (final a in accounts)
              DropdownMenuItem(
                value: a.id,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(a.label, overflow: TextOverflow.ellipsis, maxLines: 1),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      a.hasApiSession ? Icons.check_circle : Icons.warning_amber,
                      size: 16,
                      color: a.hasApiSession ? Colors.lightGreenAccent : Colors.orangeAccent,
                    ),
                  ],
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
              child: Text('Ссылка для матки ($manualHashCount)', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
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
          minLines: 3,
          maxLines: 6,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            hintText: _selectedGroupIds.isEmpty
                ? 'Ссылка для матки и дочерних (каналы сняты)'
                : 'Ссылка для вступления матки в новый канал',
            helperText: _selectedGroupIds.isEmpty
                ? 'Каналы не выбраны — дочерним уйдёт эта ссылка'
                : 'Дочерним уходит ссылка из профиля канала — не эта',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
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
          ],
        ),
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
              _selectedGroupIds.isEmpty && manualHashCount > 0
                  ? 'Только вставленная ссылка ($manualHashCount) — каналы не выбраны'
                  : 'К обработке: $targetCount ссылок (вставлено: $manualHashCount, из каналов: $selectedGroupLinkCount)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10, color: Colors.lightBlueAccent),
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(
              child: Text('Добавить в группы', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            if (accounts.length > 2) ...[
              TextButton(
                onPressed: _running
                    ? null
                    : () {
                        setState(() {
                          _childIds
                            ..clear()
                            ..addAll(
                              accounts.where((a) => a.id != _motherId).map((a) => a.id),
                            );
                        });
                        _syncMapRelations();
                      },
                child: const Text('Все', style: TextStyle(fontSize: 11)),
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
        SizedBox(
          height: 108,
          child: accounts.length <= 1
              ? const Center(child: Text('Добавьте ещё аккаунты', style: TextStyle(fontSize: 11)))
              : ListView(
                  children: [
                    for (final a in accounts.where((a) => a.id != _motherId))
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        title: Text(a.label, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                        subtitle: Row(
                          children: [
                            Expanded(
                              child: Text(
                                a.hasApiSession
                                    ? (a.viewerId != null ? 'id ${a.viewerId}' : 'токен ✓')
                                    : 'нет токена — не сможет вступить',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: a.hasApiSession ? null : Colors.orangeAccent,
                                ),
                              ),
                            ),
                            if (!a.hasApiSession)
                              TextButton(
                                onPressed: _running || _capturingToken ? null : () => _captureChildToken(a),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text('Токен', style: TextStyle(fontSize: 10)),
                              ),
                          ],
                        ),
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
                      ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Добавление дочерних: сначала по ID, если не вышло — пересылка ссылки, затем вступление дочернего',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
          ),
        ),
        Row(
          children: [
            const Text('Пауза мс', style: TextStyle(fontSize: 11)),
            const SizedBox(width: 8),
            SizedBox(
              width: 72,
              child: TextField(
                enabled: !_running,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                controller: _delayController,
              ),
            ),
          ],
        ),
        if (_childIds.isEmpty && otherAccounts.isNotEmpty)
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
              child: const Text('Только матка', style: TextStyle(fontSize: 11)),
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
    );
  }
}
