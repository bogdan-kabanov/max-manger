import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ai_chat_config.dart';
import '../providers/app_state.dart';
import '../services/ai_chat_service.dart';

class AiChatPanel extends StatefulWidget {
  const AiChatPanel({super.key});

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends State<AiChatPanel> {
  late final TextEditingController _systemPromptController;
  late final TextEditingController _targetChatsController;
  late final TextEditingController _apiBaseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  late final TextEditingController _testMessageController;

  bool _loading = false;
  String? _status;
  String? _loadedAccountId;

  @override
  void initState() {
    super.initState();
    _systemPromptController = TextEditingController();
    _targetChatsController = TextEditingController();
    _apiBaseUrlController = TextEditingController();
    _apiKeyController = TextEditingController();
    _modelController = TextEditingController();
    _testMessageController = TextEditingController(text: 'Привет! Как дела?');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final accountId = context.watch<AppState>().selectedAccount?.id;
    if (accountId != null && accountId != _loadedAccountId) {
      _loadedAccountId = accountId;
      _loadFromState();
    }
  }

  void _loadFromState() {
    final config = context.read<AppState>().aiConfigForSelected();
    _systemPromptController.text = config.systemPrompt;
    _targetChatsController.text = config.targetChats.join(', ');
    _apiBaseUrlController.text = config.apiBaseUrl;
    _apiKeyController.text = config.apiKey;
    _modelController.text = config.model;
  }

  @override
  void dispose() {
    _systemPromptController.dispose();
    _targetChatsController.dispose();
    _apiBaseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _testMessageController.dispose();
    super.dispose();
  }

  AiChatConfig _buildDraft(bool enabled) {
    final accountId = context.read<AppState>().selectedAccount!.id;
    return AiChatConfig(
      accountId: accountId,
      enabled: enabled,
      systemPrompt: _systemPromptController.text.trim(),
      targetChats: _targetChatsController.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      apiBaseUrl: _apiBaseUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
    );
  }

  Future<void> _save({bool? enabled}) async {
    final state = context.read<AppState>();
    if (state.selectedAccount == null) return;

    final current = state.aiConfigForSelected();
    final draft = _buildDraft(enabled ?? current.enabled);
    await state.saveAiConfig(draft);
    if (mounted) {
      setState(() => _status = 'Сохранено');
    }
  }

  Future<void> _testApi() async {
    final state = context.read<AppState>();
    if (state.selectedAccount == null) return;

    setState(() {
      _loading = true;
      _status = null;
    });

    try {
      final draft = _buildDraft(state.aiConfigForSelected().enabled);
      final reply = await AiChatService.complete(
        config: draft,
        userMessage: _testMessageController.text.trim().isEmpty
            ? 'Привет!'
            : _testMessageController.text.trim(),
        chatTitle: 'Тест',
      );
      if (mounted) {
        setState(() => _status = 'ИИ ответил: $reply');
      }
    } on AiChatException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.aiConfigForSelected();
    final hasAccount = state.selectedAccount != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('ИИ-ответы включены'),
                  subtitle: const Text('Бот отвечает на сообщения в открытом чате'),
                  value: config.enabled,
                  onChanged: hasAccount
                      ? (value) async {
                          await _save(enabled: value);
                        }
                      : null,
                ),
                const SizedBox(height: 8),
                const Text(
                  'ИИ работает через WebSocket API (ws-api.oneme.ru), без DOM. '
                  'Нужен токен аккаунта. Бот отвечает на входящие от собеседника.',
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _systemPromptController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Манера общения (system prompt)',
                    hintText: 'Ты продавец. Отвечай вежливо, предлагай товар...',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _targetChatsController,
                  decoration: const InputDecoration(
                    labelText: 'Целевые чаты',
                    hintText: 'НАША ДАЧА, Иван (пусто = любой открытый)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _apiBaseUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.typfc.com/v1',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _apiKeyController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API-ключ',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _modelController,
                  decoration: const InputDecoration(
                    labelText: 'Модель',
                    hintText: 'sonnet-4.6',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _testMessageController,
                  decoration: const InputDecoration(
                    labelText: 'Тестовое сообщение',
                  ),
                ),
                if (_status != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _status!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _status!.startsWith('ИИ ответил')
                          ? Colors.greenAccent
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: !hasAccount || _loading ? null : () => _save(),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Сохранить настройки'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: !hasAccount || _loading ? null : _testApi,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.smart_toy_outlined),
                  label: const Text('Проверить API'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: !hasAccount || _loading
                      ? null
                      : () => state.reconnectAiWs(),
                  icon: const Icon(Icons.wifi),
                  label: const Text('Переподключить WS'),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: !hasAccount || _loading || !config.enabled
                      ? null
                      : () async {
                          setState(() {
                            _loading = true;
                            _status = null;
                          });
                          try {
                            await state.triggerTestReplyInChat(
                              _testMessageController.text.trim().isEmpty
                                  ? 'Привет!'
                                  : _testMessageController.text.trim(),
                            );
                            if (mounted) setState(() => _status = 'Запрос отправлен — смотрите журнал');
                          } finally {
                            if (mounted) setState(() => _loading = false);
                          }
                        },
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Ответить в чат'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
