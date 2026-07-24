import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/account_map_state.dart';
import '../models/active_action.dart';
import '../models/app_nav_page.dart';
import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import '../models/mother_group_channel.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';
import '../services/max_mother_service.dart';
import '../services/storage_service.dart';

class ChannelCatalogPanel extends StatefulWidget {
  const ChannelCatalogPanel({super.key, this.embedded = false});

  /// When true, slightly tighter padding for nested layouts.
  final bool embedded;

  @override
  State<ChannelCatalogPanel> createState() => _ChannelCatalogPanelState();
}

class _ChannelCatalogPanelState extends State<ChannelCatalogPanel> {
  final _keywordController = TextEditingController();
  final _countController = TextEditingController(text: '30');
  final _liveLogScroll = ScrollController();
  String? _accountId;
  bool _running = false;
  bool _cliReady = false;
  int _addCount = 30;
  int _batchSize = 10;
  int _foundThisRun = 0;
  int _targetThisRun = 0;
  int _batchThisRun = 0;
  String _statusLine = '';
  /// chats = можно писать, channels = лента, all = оба
  String _discoverKind = 'chats';
  List<MaxChannelCatalogEntry> _catalog = const [];
  final _selectedChannelIds = <String>{};
  final _selectedMotherAccountIds = <String>{};
  final _liveLogs = <String>[];
  final _keywords = <String>[];

  static const _countOptions = [5, 10, 20, 30, 50, 100];
  static const _batchOptions = [5, 10, 15, 20];
  static const _minCount = 1;
  static const _maxCount = 200;
  static const _keywordSuggestions = [
    'чат',
    'группа',
    'крипто',
    'работа',
    'знакомства',
    'москва',
    'игры',
    'продажа',
    'аренда',
    'вакансии',
  ];

  @override
  void initState() {
    super.initState();
    _catalog = StorageService.instance.channelCatalogEntries;
    _keywords.addAll(StorageService.instance.discoverKeywords);
    _selectedChannelIds.addAll(_catalog.where((e) => e.hasInviteLink).map((e) => e.chatId));
    MaxMotherService.isAvailable().then((v) {
      if (mounted) setState(() => _cliReady = v);
    });
  }

  @override
  void dispose() {
    _keywordController.dispose();
    _countController.dispose();
    _liveLogScroll.dispose();
    super.dispose();
  }

  void _log(String msg, {String level = 'info'}) {
    context.read<BrowserSessionManager>().logMessage('[Каталог] $msg', level: level);
    if (!mounted) return;
    setState(() {
      _liveLogs.add(msg);
      if (_liveLogs.length > 300) {
        _liveLogs.removeRange(0, _liveLogs.length - 300);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_liveLogScroll.hasClients) return;
      _liveLogScroll.jumpTo(_liveLogScroll.position.maxScrollExtent);
    });
  }

  void _reloadCatalog({bool selectNew = false}) {
    final prev = _catalog.map((e) => e.chatId).toSet();
    final next = StorageService.instance.channelCatalogEntries;
    setState(() {
      _catalog = next;
      if (selectNew) {
        for (final e in next) {
          if (e.hasInviteLink && !prev.contains(e.chatId)) {
            _selectedChannelIds.add(e.chatId);
          }
        }
      }
      _selectedChannelIds.removeWhere((id) => !_catalog.any((e) => e.chatId == id));
    });
  }

  MaxAccount? _account(AppState state) => state.accountById(_accountId);

  void _applyCount(int n) {
    final clamped = n.clamp(_minCount, _maxCount);
    setState(() {
      _addCount = clamped;
      _countController.text = '$clamped';
    });
  }

  void _syncCountFromField() {
    final raw = _countController.text.trim();
    final n = int.tryParse(raw);
    if (n == null) {
      _countController.text = '$_addCount';
      return;
    }
    _applyCount(n);
  }

  List<String> _parseKeywordChunk(String raw) {
    return raw
        .split(RegExp(r'[,;\n|]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
  }

  Future<void> _persistKeywords() async {
    await StorageService.instance.saveDiscoverKeywords(_keywords);
  }

  Future<void> _addKeywordsFromInput({String? raw}) async {
    final chunk = _parseKeywordChunk(raw ?? _keywordController.text);
    if (chunk.isEmpty) return;
    var added = 0;
    setState(() {
      for (final word in chunk) {
        final exists = _keywords.any((k) => k.toLowerCase() == word.toLowerCase());
        if (!exists) {
          _keywords.add(word);
          added++;
        }
      }
      _keywordController.clear();
    });
    if (added > 0) {
      await _persistKeywords();
      _log('Ключевых слов: ${_keywords.length} (+$added)');
    }
  }

  Future<void> _removeKeyword(String word) async {
    setState(() => _keywords.removeWhere((k) => k == word));
    await _persistKeywords();
  }

  Future<void> _clearKeywords() async {
    setState(() => _keywords.clear());
    await _persistKeywords();
  }

  Future<void> _pasteKeywords() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _log('Буфер пуст', level: 'warn');
      return;
    }
    await _addKeywordsFromInput(raw: text);
  }

  List<String> _excludeHashes({required bool openSearch}) {
    // Open search (no keywords): only skip what's already in the current catalog,
    // so "чаты без слов" действительно ищет любые чаты, а не обходит 200 старых.
    if (openSearch) {
      return _catalog.where((e) => e.hasInviteLink).map((e) => e.inviteHash!).toList();
    }
    return <String>{
      ...StorageService.instance.discoverExcludeHashes,
      ..._catalog.where((e) => e.hasInviteLink).map((e) => e.inviteHash!),
    }.toList();
  }

  List<String> _excludeChatIds({required bool openSearch}) {
    if (openSearch) {
      return _catalog.map((e) => e.chatId).toList();
    }
    return <String>{
      ...StorageService.instance.discoverExcludeChatIds,
      ..._catalog.map((e) => e.chatId),
    }.toList();
  }

  List<({MotherCluster cluster, MaxAccount mother})> _readyMothers(AppState state) {
    final out = <({MotherCluster cluster, MaxAccount mother})>[];
    for (final cluster in state.motherClusters) {
      final id = cluster.motherAccountId;
      if (id == null) continue;
      final mother = state.accountById(id);
      if (mother == null || !mother.hasApiSession) continue;
      out.add((cluster: cluster, mother: mother));
    }
    return out;
  }

  Set<String> _motherJoinedChatIds(String motherAccountId) {
    return StorageService.instance.motherGroupsFor(motherAccountId).map((g) => g.chatId).toSet();
  }

  String _mothersLabelForChannel(AppState state, String chatId) {
    final entry = state.channelCatalog.cast<MaxChannelCatalogEntry?>().firstWhere(
          (e) => e?.chatId == chatId,
          orElse: () => null,
        );
    if (entry != null && entry.isAssigned) {
      final label = state.accountById(entry.assignedMotherAccountId!)?.label ??
          entry.assignedMotherAccountId!;
      return 'назначена: $label';
    }
    final names = <String>[];
    for (final row in _readyMothers(state)) {
      if (_motherJoinedChatIds(row.mother.id).contains(chatId)) {
        names.add(row.cluster.name);
      }
    }
    if (names.isEmpty) return 'свободна';
    return 'вступила: ${names.join(', ')}';
  }

  Future<void> _discover() async {
    _syncCountFromField();
    final state = context.read<AppState>();
    final account = _account(state);
    if (account == null || !account.hasApiSession) {
      _log('Выберите аккаунт с API-токеном', level: 'warn');
      return;
    }
    if (!_cliReady) {
      _log('CLI недоступен — нужен Node.js и npm install в tools/max_auth', level: 'warn');
      return;
    }

    final topicRaw = _keywordController.text.trim();
    // Pending text in the field is also used for this run.
    final topics = <String>{
      ..._keywords,
      ..._parseKeywordChunk(topicRaw),
    }.toList();

    final target = _addCount;
    final openSearch = topics.isEmpty;
    // Open search: one CLI call for the full target (no tiny batches that reconnect).
    final batchSize = openSearch ? target.clamp(1, 200) : _batchSize.clamp(1, 50);
    setState(() {
      _running = true;
      _foundThisRun = 0;
      _targetThisRun = target;
      _batchThisRun = 0;
      _statusLine = 'Старт…';
      _liveLogs.clear();
    });

    final known = StorageService.instance.seenDiscoverCount;
    final kindLabel = switch (_discoverKind) {
      'channels' => 'каналов',
      'all' => 'чатов и каналов',
      _ => 'чатов (можно писать)',
    };
    _log(
      openSearch
          ? (_discoverKind == 'chats'
              ? 'Импорт чатов с max-catalog.com: до $target (без ключевых слов)'
              : 'Открытый поиск: до $target любых $kindLabel (без ключевых слов — не пропускаем старую историю)')
          : 'Ищем до $target $kindLabel пачками по $batchSize'
              ' · ключевые слова: ${topics.join(', ')}'
              ' · уже известных: $known',
    );

    var totalAdded = 0;
    var emptyStreak = 0;
    var batchNo = 0;
    final action = state.beginAction(
      kind: ActiveActionKind.discoverChannels,
      title: 'Поиск каналов',
      subtitle: 'до $target · $kindLabel',
    );

    try {
      await state.ensureViewerId(account);
      final fresh = state.accountById(account.id)!;

      while (totalAdded < target && mounted && !action.cancelToken.isCancelled) {
        batchNo++;
        final need = target - totalAdded;
        final ask = need < batchSize ? need : batchSize;
        if (!mounted) return;
        setState(() {
          _batchThisRun = batchNo;
          _foundThisRun = totalAdded;
          _statusLine = openSearch
              ? 'Открытый поиск · до $ask · есть $totalAdded'
              : 'Партия $batchNo · до $ask · есть $totalAdded (макс. $target)';
        });
        state.updateActionProgress(
          action.id,
          message: _statusLine,
          done: totalAdded,
          total: target,
        );
        _log(
          openSearch
              ? '─── Открытый поиск: запрос до $ask ───'
              : '─── Партия $batchNo: запрос до $ask (уже $totalAdded, макс. $target) ───',
        );

        final result = await MaxMotherService.discoverChannels(
          token: fresh.apiToken!,
          count: ask,
          topics: topics,
          kind: _discoverKind,
          excludeHashes: _excludeHashes(openSearch: openSearch),
          excludeChatIds: _excludeChatIds(openSearch: openSearch),
          proxy: fresh.isolation.proxyServer,
          cancel: action.cancelToken,
          onProgress: (msg) {
            final cleaned = msg.replaceFirst(RegExp(r'^\[Каталог\]\s*'), '');
            _log(cleaned);
            state.updateActionProgress(action.id, message: cleaned);
          },
        );

        if (!mounted || action.cancelToken.isCancelled) return;

        final got = result.channels.length;
        if (got > 0) {
          await StorageService.instance.mergeChannelCatalog(result.channels);
          _reloadCatalog(selectNew: true);
          totalAdded += got;
          emptyStreak = 0;
          _log(
            'Партия $batchNo: +$got добавлено → всего $totalAdded '
            '(макс. $target) · в базе ${_catalog.length}',
          );
        } else {
          emptyStreak++;
          _log(
            result.ok
                ? 'Партия $batchNo: новых нет ($emptyStreak подряд)'
                : 'Партия $batchNo: ${result.message}',
            level: result.ok ? 'info' : 'warn',
          );
          // Уже что-то нашли — не долбим цель дальше при пустых партиях.
          final emptyLimit = totalAdded > 0 ? 2 : 3;
          if (emptyStreak >= emptyLimit) {
            _log(
              totalAdded > 0
                  ? 'Новых больше нет — оставляем найденные ($totalAdded), цель $target не обязательна'
                  : 'Три пустые партии подряд — останавливаем поиск',
              level: 'warn',
            );
            break;
          }
        }

        if (!mounted) return;
        setState(() {
          _foundThisRun = totalAdded;
          _statusLine = 'Партия $batchNo · $totalAdded (макс. $target)';
        });

        if (totalAdded < target) {
          await delayUnlessCancelled(
            const Duration(milliseconds: 400),
            token: action.cancelToken,
          );
        }
      }

      if (action.cancelToken.isCancelled) {
        _log('Поиск остановлен (найдено $totalAdded)', level: 'warn');
      } else {
        _log(
          totalAdded >= target
              ? 'Готово: набрано $totalAdded (лимит $target). '
                  'В базе: ${_catalog.length}. Известных: ${StorageService.instance.seenDiscoverCount}'
              : 'Готово: добавлено $totalAdded'
                  '${totalAdded > 0 ? ' — всё что нашлось' : ''}'
                  ' (цель была до $target). '
                  'В базе: ${_catalog.length}. Известных: ${StorageService.instance.seenDiscoverCount}',
        );
      }
    } finally {
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
        message: 'Добавлено $totalAdded',
      );
      if (mounted) {
        setState(() {
          _running = false;
          _statusLine = action.cancelToken.isCancelled
              ? 'Остановлено · $totalAdded'
              : totalAdded > 0
                  ? (totalAdded >= target
                      ? 'Добавлено $totalAdded'
                      : 'Добавлено $totalAdded — всё что нашлось (до $target)')
                  : 'Новых каналов не найдено';
        });
      }
    }
  }

  Future<void> _joinSelectedToMothers() async {
    final state = context.read<AppState>();
    final mothers = _readyMothers(state)
        .where((row) => _selectedMotherAccountIds.contains(row.mother.id))
        .toList();
    if (mothers.isEmpty) {
      _log('Отметьте родителей, куда вступать', level: 'warn');
      return;
    }

    final channels = _catalog
        .where((e) => _selectedChannelIds.contains(e.chatId) && e.hasInviteLink)
        .toList();
    if (channels.isEmpty) {
      _log('Отметьте каналы со ссылкой', level: 'warn');
      return;
    }

    final delay = state.rateSettings.motherJoinDelayMs;
    setState(() => _running = true);
    _log(
      '─── Вступление: ${channels.length} кан. → ${mothers.length} мат. ───',
    );
    final action = state.beginAction(
      kind: ActiveActionKind.joinChannels,
      title: 'Вступление в каналы',
      subtitle: '${channels.length} кан. → ${mothers.length} мат.',
    );

    try {
      var motherDone = 0;
      for (final row in mothers) {
        if (action.cancelToken.isCancelled) break;
        final mother = row.mother;
        final joined = _motherJoinedChatIds(mother.id);
        final targets = channels.where((c) => !joined.contains(c.chatId)).toList();
        if (targets.isEmpty) {
          _log('«${row.cluster.name}»: все выбранные уже есть — пропуск');
          motherDone += 1;
          continue;
        }

        if (state.browser.activeAccount?.id == mother.id) {
          _log('⚠ «${mother.label}» открыт в MAX — закрываем браузер');
          await state.browser.releaseWebview();
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }

        await state.ensureViewerId(mother);
        final fresh = state.accountById(mother.id)!;
        final urls = targets.map((e) => e.inviteUrl!).toList();
        _log('«${row.cluster.name}» (${fresh.label}): вступление в ${urls.length}…');
        state.updateActionProgress(
          action.id,
          message: '«${row.cluster.name}» · ${urls.length} ссылок',
          done: motherDone,
          total: mothers.length,
        );

        final result = await MaxMotherService.joinGroups(
          token: fresh.apiToken!,
          links: urls,
          delayMs: delay,
          proxy: fresh.isolation.proxyServer,
          cancel: action.cancelToken,
          onProgress: (msg) {
            _log(msg);
            state.updateActionProgress(action.id, message: msg);
          },
        );

        if (result.groups.isNotEmpty) {
          await StorageService.instance.mergeMotherGroups(mother.id, result.groups);
        } else {
          final byChat = {for (final c in targets) c.chatId: c};
          final byHash = {
            for (final c in targets)
              if (c.inviteHash != null) c.inviteHash!: c,
          };
          final okGroups = <MotherGroupChannel>[];
          for (final r in result.results) {
            if (r['ok'] != true) continue;
            final chatId = r['chatId']?.toString();
            if (chatId == null || chatId.isEmpty) continue;
            final match = byChat[chatId] ?? byHash[r['hash']?.toString()];
            okGroups.add(
              MotherGroupChannel(
                chatId: chatId,
                title: r['title']?.toString() ?? match?.title ?? chatId,
                inviteHash: match?.inviteHash ?? r['hash']?.toString(),
                updatedAt: DateTime.now(),
              ),
            );
          }
          if (okGroups.isNotEmpty) {
            await StorageService.instance.mergeMotherGroups(mother.id, okGroups);
          }
        }

        motherDone += 1;
        _log(
          result.ok
              ? '✓ «${row.cluster.name}»: ${result.message}'
              : '✗ «${row.cluster.name}»: ${result.message}',
        );
      }
      if (action.cancelToken.isCancelled) {
        _log('Вступление остановлено', level: 'warn');
      }
      if (mounted) setState(() {});
    } finally {
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
      );
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _copyLink(MaxChannelCatalogEntry entry) async {
    final url = entry.inviteUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    _log('Скопировано: $url');
  }

  Future<void> _copySelectedLinks() async {
    final urls = _catalog
        .where((e) => _selectedChannelIds.contains(e.chatId) && e.hasInviteLink)
        .map((e) => e.inviteUrl!)
        .toList();
    if (urls.isEmpty) {
      _log('Нет выбранных ссылок', level: 'warn');
      return;
    }
    await Clipboard.setData(ClipboardData(text: urls.join('\n')));
    _log('Скопировано ${urls.length} ссылок');
  }

  Future<void> _removeEntry(MaxChannelCatalogEntry entry) async {
    final next = _catalog.where((e) => e.chatId != entry.chatId).toList();
    await StorageService.instance.saveChannelCatalog(next);
    _reloadCatalog();
  }

  Future<void> _clearCatalog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить базу?'),
        content: Text(
          'Удалить все ${_catalog.length} каналов из каталога?\n\n'
          'История уже найденных (${StorageService.instance.seenDiscoverCount}) сохранится — '
          'повторный поиск не будет предлагать те же группы.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Очистить')),
        ],
      ),
    );
    if (confirmed != true) return;
    await StorageService.instance.saveChannelCatalog(const []);
    _reloadCatalog();
    _selectedChannelIds.clear();
    _log('База каналов очищена (известных для пропуска: ${StorageService.instance.seenDiscoverCount})');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final accounts = state.accounts.where((a) => a.hasApiSession).toList();
    final selected = state.selectedAccount;
    final mothers = _readyMothers(state);

    if (_accountId == null || !accounts.any((a) => a.id == _accountId)) {
      _accountId = selected?.hasApiSession == true
          ? selected!.id
          : (accounts.isNotEmpty ? accounts.first.id : null);
    }

    // Drop mother selection if cluster removed.
    _selectedMotherAccountIds.removeWhere((id) => !mothers.any((m) => m.mother.id == id));

    final account = _account(state);
    final withLinks = _catalog.where((e) => e.hasInviteLink).length;
    final selectedWithLink = _catalog
        .where((e) => _selectedChannelIds.contains(e.chatId) && e.hasInviteLink)
        .length;
    final pad = widget.embedded ? const EdgeInsets.fromLTRB(12, 8, 12, 12) : const EdgeInsets.fromLTRB(16, 12, 16, 16);
    final buttonLabel = _running
        ? (_statusLine.isNotEmpty ? _statusLine : 'Ищем…')
        : 'Искать до $_addCount';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: pad,
            children: [
        Text(
          '«Чаты» берём с внешнего каталога max-catalog.com (у MAX нет публичного индекса групповых чатов), '
          'после resolve оставляем только тип CHAT. «Каналы» — через поиск MAX. '
          'С ключевыми словами уже найденные (${StorageService.instance.seenDiscoverCount}) не повторяются.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Text('Что искать', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              label: const Text('Чаты (писать)', style: TextStyle(fontSize: 11)),
              selected: _discoverKind == 'chats',
              onSelected: _running
                  ? null
                  : (v) {
                      if (v) setState(() => _discoverKind = 'chats');
                    },
            ),
            ChoiceChip(
              label: const Text('Каналы', style: TextStyle(fontSize: 11)),
              selected: _discoverKind == 'channels',
              onSelected: _running
                  ? null
                  : (v) {
                      if (v) setState(() => _discoverKind = 'channels');
                    },
            ),
            ChoiceChip(
              label: const Text('Всё', style: TextStyle(fontSize: 11)),
              selected: _discoverKind == 'all',
              onSelected: _running
                  ? null
                  : (v) {
                      if (v) setState(() => _discoverKind = 'all');
                    },
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (accounts.isEmpty)
          Text(
            'Добавьте аккаунт с API-токеном — он нужен для поиска каналов.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
          )
        else
          DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _accountId,
            decoration: const InputDecoration(
              labelText: 'Аккаунт для поиска',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.label, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _running ? null : (id) => setState(() => _accountId = id),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'Ключевые слова (${_keywords.length})',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            TextButton(
              onPressed: _running ? null : _pasteKeywords,
              child: const Text('Вставить', style: TextStyle(fontSize: 11)),
            ),
            if (_keywords.isNotEmpty)
              TextButton(
                onPressed: _running ? null : _clearKeywords,
                child: const Text('Сбросить', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _keywordController,
                enabled: !_running,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'слово + Enter — или через запятую',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addKeywordsFromInput(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _running ? null : () => _addKeywordsFromInput(),
              child: const Text('Добавить'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_keywords.isEmpty)
          Text(
            'Без слов поиск идёт по случайным темам. Добавьте, например: крипто, работа, чат.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final word in _keywords)
                InputChip(
                  label: Text(word, style: const TextStyle(fontSize: 11)),
                  onDeleted: _running ? null : () => _removeKeyword(word),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final tip in _keywordSuggestions)
              if (!_keywords.any((k) => k.toLowerCase() == tip.toLowerCase()))
                ActionChip(
                  label: Text('+$tip', style: const TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact,
                  onPressed: _running ? null : () => _addKeywordsFromInput(raw: tip),
                ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Максимум добавить (1–$_maxCount) — меньше тоже ок',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            SizedBox(
              width: 72,
              child: TextField(
                controller: _countController,
                enabled: !_running,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                onSubmitted: (_) => _syncCountFromField(),
                onEditingComplete: _syncCountFromField,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final n in _countOptions)
                    ChoiceChip(
                      label: Text('$n', style: const TextStyle(fontSize: 11)),
                      selected: _addCount == n,
                      onSelected: _running
                          ? null
                          : (v) {
                              if (v) _applyCount(n);
                            },
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text('Размер партии', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final n in _batchOptions)
              ChoiceChip(
                label: Text('по $n', style: const TextStyle(fontSize: 11)),
                selected: _batchSize == n,
                onSelected: _running
                    ? null
                    : (v) {
                        if (v) setState(() => _batchSize = n);
                      },
              ),
          ],
        ),
        if (_running || _statusLine.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _running
                ? '$_statusLine${_targetThisRun > 0 ? '' : ''}'
                : _statusLine,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: Colors.lightBlueAccent,
                ),
          ),
          if (_running && _targetThisRun > 0) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: (_foundThisRun / _targetThisRun).clamp(0.0, 1.0),
              minHeight: 4,
            ),
          ],
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _running || account == null
                    ? null
                    : () {
                        _syncCountFromField();
                        _discover();
                      },
                icon: _running
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_link, size: 18),
                label: Text(buttonLabel, overflow: TextOverflow.ellipsis),
              ),
            ),
            if (_catalog.isNotEmpty) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Очистить базу',
                onPressed: _running ? null : _clearCatalog,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ],
        ),
        if (!_cliReady)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Node CLI не найден. Выполните: cd tools/max_auth && npm install',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 11,
                  ),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          'Матки для вступления (${_selectedMotherAccountIds.length}/${mothers.length})',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        ),
        const SizedBox(height: 4),
        if (mothers.isEmpty)
          Text(
            'Создайте кластер во вкладке «Раздача» и привяжите аккаунт с токеном.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
          )
        else ...[
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: _running
                    ? null
                    : () => setState(() {
                          _selectedMotherAccountIds
                            ..clear()
                            ..addAll(mothers.map((m) => m.mother.id));
                        }),
                child: const Text('Все', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: _running ? null : () => setState(() => _selectedMotherAccountIds.clear()),
                child: const Text('Снять', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          ...mothers.map(
            (row) => CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(row.cluster.name, style: const TextStyle(fontSize: 12)),
              subtitle: Text(
                row.mother.label,
                style: const TextStyle(fontSize: 10),
                overflow: TextOverflow.ellipsis,
              ),
              value: _selectedMotherAccountIds.contains(row.mother.id),
              onChanged: _running
                  ? null
                  : (v) {
                      setState(() {
                        if (v == true) {
                          _selectedMotherAccountIds.add(row.mother.id);
                        } else {
                          _selectedMotherAccountIds.remove(row.mother.id);
                        }
                      });
                    },
            ),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: _running
                ? null
                : () => context.read<AppState>().setNavPage(AppNavPage.assign),
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text(
              'Дальше: Раздача родителям',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (selectedWithLink > 0 && _selectedMotherAccountIds.isNotEmpty) ...[
            const SizedBox(height: 4),
            TextButton(
              onPressed: _running || !_cliReady ? null : _joinSelectedToMothers,
              child: Text(
                'Сразу вступить (старое): $selectedWithLink → ${_selectedMotherAccountIds.length} мат.',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                'В базе: ${_catalog.length} (со ссылкой: $withLinks, выбрано: ${_selectedChannelIds.length})',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ),
            if (_catalog.isNotEmpty) ...[
              TextButton(
                onPressed: _running
                    ? null
                    : () => setState(() {
                          _selectedChannelIds
                            ..clear()
                            ..addAll(_catalog.where((e) => e.hasInviteLink).map((e) => e.chatId));
                        }),
                child: const Text('Все', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: _running ? null : () => setState(() => _selectedChannelIds.clear()),
                child: const Text('Снять', style: TextStyle(fontSize: 11)),
              ),
            ],
            if (selectedWithLink > 0)
              IconButton(
                tooltip: 'Скопировать выбранные',
                onPressed: _running ? null : _copySelectedLinks,
                icon: const Icon(Icons.copy_all, size: 18),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (_catalog.isEmpty)
          Text(
            'Нажмите «Искать до $_addCount» — всё найденное сразу попадает в базу, даже если меньше лимита.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
          )
        else
          ..._catalog.map(
            (entry) => Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: CheckboxListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 8, right: 4),
                value: _selectedChannelIds.contains(entry.chatId),
                onChanged: _running || !entry.hasInviteLink
                    ? null
                    : (v) {
                        setState(() {
                          if (v == true) {
                            _selectedChannelIds.add(entry.chatId);
                          } else {
                            _selectedChannelIds.remove(entry.chatId);
                          }
                        });
                      },
                title: Text(entry.title, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    if (entry.type != null) entry.type!,
                    if (entry.topic != null) entry.topic!,
                    if (entry.hasInviteLink) 'есть ссылка' else 'нет ссылки',
                    _mothersLabelForChannel(state, entry.chatId),
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 10,
                    color: entry.hasInviteLink ? null : Colors.orangeAccent,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                secondary: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (entry.hasInviteLink)
                      IconButton(
                        tooltip: 'Копировать',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => _copyLink(entry),
                      ),
                    IconButton(
                      tooltip: 'Удалить из базы',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _running ? null : () => _removeEntry(entry),
                    ),
                  ],
                ),
              ),
            ),
          ),
            ],
          ),
        ),
        _buildLiveLog(context),
      ],
    );
  }

  Widget _buildLiveLog(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
      child: SizedBox(
        height: 168,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 2),
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 14),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Лог поиска',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                    ),
                  ),
                  if (_running)
                    Text(
                      'партия $_batchThisRun · $_foundThisRun/$_targetThisRun',
                      style: const TextStyle(fontSize: 10, color: Colors.lightBlueAccent),
                    ),
                  TextButton(
                    onPressed: _liveLogs.isEmpty ? null : () => setState(() => _liveLogs.clear()),
                    child: const Text('Очистить', style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _liveLogs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Здесь будут идти сообщения по ходу поиска и вступления.',
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, color: theme.hintColor),
                      ),
                    )
                  : ListView.builder(
                      controller: _liveLogScroll,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      itemCount: _liveLogs.length,
                      itemBuilder: (context, index) {
                        final line = _liveLogs[index];
                        final warn = line.contains('⚠') || line.toLowerCase().contains('ошиб');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            line,
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'Consolas',
                              height: 1.25,
                              color: warn ? Colors.orangeAccent : null,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
