import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';
import '../services/max_mother_service.dart';
import '../services/storage_service.dart';

class ChannelCatalogPanel extends StatefulWidget {
  const ChannelCatalogPanel({super.key});

  @override
  State<ChannelCatalogPanel> createState() => _ChannelCatalogPanelState();
}

class _ChannelCatalogPanelState extends State<ChannelCatalogPanel> {
  final _topicController = TextEditingController();
  String? _accountId;
  bool _running = false;
  bool _cliReady = false;
  int _addCount = 10;
  List<MaxChannelCatalogEntry> _catalog = const [];

  static const _countOptions = [5, 10, 20, 30];

  @override
  void initState() {
    super.initState();
    _catalog = StorageService.instance.channelCatalogEntries;
    MaxMotherService.isAvailable().then((v) {
      if (mounted) setState(() => _cliReady = v);
    });
  }

  @override
  void dispose() {
    _topicController.dispose();
    super.dispose();
  }

  void _log(String msg, {String level = 'info'}) {
    context.read<BrowserSessionManager>().logMessage('[Каталог] $msg', level: level);
  }

  void _reloadCatalog() {
    setState(() => _catalog = StorageService.instance.channelCatalogEntries);
  }

  MaxAccount? _account(AppState state) => state.accountById(_accountId);

  List<String> _excludeHashes() {
    return _catalog
        .where((e) => e.hasInviteLink)
        .map((e) => e.inviteHash!)
        .toList();
  }

  List<String> _excludeChatIds() => _catalog.map((e) => e.chatId).toList();

  Future<void> _discover() async {
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

    final topicRaw = _topicController.text.trim();
    final topics = topicRaw.isEmpty
        ? const <String>[]
        : topicRaw.split(RegExp(r'[,;|]+')).map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

    setState(() => _running = true);
    _log('Ищем $_addCount каналов${topics.isNotEmpty ? ' по темам: ${topics.join(', ')}' : ' на случайные темы'}…');

    try {
      await state.ensureViewerId(account);
      final fresh = state.accountById(account.id)!;
      final result = await MaxMotherService.discoverChannels(
        token: fresh.apiToken!,
        count: _addCount,
        topics: topics,
        excludeHashes: _excludeHashes(),
        excludeChatIds: _excludeChatIds(),
        proxy: fresh.isolation.proxyServer,
        onProgress: _log,
      );

      if (!mounted) return;

      if (result.channels.isNotEmpty) {
        await StorageService.instance.mergeChannelCatalog(result.channels);
        _reloadCatalog();
      }

      if (result.ok || result.channels.isNotEmpty) {
        _log('Добавлено ${result.channels.length} из $_addCount. Всего в базе: ${_catalog.length}');
      } else {
        _log(result.message, level: 'warn');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _copyLink(MaxChannelCatalogEntry entry) async {
    final url = entry.inviteUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    _log('Скопировано: $url');
  }

  Future<void> _copyAllLinks() async {
    final urls = _catalog.where((e) => e.hasInviteLink).map((e) => e.inviteUrl!).toList();
    if (urls.isEmpty) {
      _log('Нет ссылок для копирования', level: 'warn');
      return;
    }
    await Clipboard.setData(ClipboardData(text: urls.join('\n')));
    _log('Скопировано ${urls.length} ссылок (по одной на строку)');
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
        content: Text('Удалить все ${_catalog.length} каналов из каталога?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Очистить')),
        ],
      ),
    );
    if (confirmed != true) return;
    await StorageService.instance.saveChannelCatalog(const []);
    _reloadCatalog();
    _log('База каналов очищена');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final accounts = state.accounts.where((a) => a.hasApiSession).toList();
    final selected = state.selectedAccount;

    if (_accountId == null || !accounts.any((a) => a.id == _accountId)) {
      _accountId = selected?.hasApiSession == true
          ? selected!.id
          : (accounts.isNotEmpty ? accounts.first.id : null);
    }

    final account = _account(state);
    final withLinks = _catalog.where((e) => e.hasInviteLink).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        Text(
          'База уникальных каналов MAX. Поиск идёт через глобальный поиск и сканирование чатов аккаунта.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (accounts.isEmpty)
          Text(
            'Добавьте аккаунт с API-токеном — он нужен для поиска каналов.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
          )
        else
          DropdownButtonFormField<String>(
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
            onChanged: _running
                ? null
                : (id) => setState(() => _accountId = id),
          ),
        const SizedBox(height: 10),
        TextField(
          controller: _topicController,
          enabled: !_running,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
            labelText: 'Тема (необязательно)',
            hintText: 'крипто, новости — или пусто для случайных тем',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Text('Сколько добавить', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final n in _countOptions)
              ChoiceChip(
                label: Text('$n'),
                selected: _addCount == n,
                onSelected: _running
                    ? null
                    : (v) {
                        if (v) setState(() => _addCount = n);
                      },
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _running || account == null ? null : _discover,
                icon: _running
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_link, size: 18),
                label: Text('Добавить $_addCount'),
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
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                'В базе: ${_catalog.length} (со ссылкой: $withLinks)',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ),
            if (withLinks > 0)
              TextButton.icon(
                onPressed: _running ? null : _copyAllLinks,
                icon: const Icon(Icons.copy_all, size: 16),
                label: const Text('Скопировать все', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (_catalog.isEmpty)
          Text(
            'Нажмите «Добавить $_addCount» — приложение найдёт каналы и сохранит invite-ссылки.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
          )
        else
          ..._catalog.map(
            (entry) => Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                title: Text(entry.title, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    if (entry.topic != null) entry.topic!,
                    if (entry.hasInviteLink) entry.inviteUrl!,
                  ].join(' · '),
                  style: const TextStyle(fontSize: 10),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (entry.hasInviteLink)
                      IconButton(
                        tooltip: 'Копировать ссылку',
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
    );
  }
}
