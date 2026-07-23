import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../utils/message_link_markup.dart';
import 'proxy_support.dart';

class MaxIncomingMessage {
  MaxIncomingMessage({
    required this.messageId,
    required this.chatId,
    required this.text,
    this.chatTitle,
    this.sender,
  });

  final String messageId;
  final String chatId;
  final String text;
  final String? chatTitle;
  final int? sender;

  String get dedupeKey => messageId.isNotEmpty ? messageId : '$chatId::$text';
}

class MaxWsService extends ChangeNotifier {
  static const _wsUrl = 'wss://ws-api.oneme.ru/websocket';
  static const _rpcVersion = 11;
  static const _messageReceivedOpcode = 128;
  static const _sendMessageOpcode = 64;
  static const _helloOpcode = 6;
  static const _loginOpcode = 19;
  static const _keepaliveOpcode = 1;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  Timer? _keepalive;
  int _seq = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  bool _loggedIn = false;
  int? _viewerId;
  String? _activeToken;
  List<String> _targetChats = [];

  final Map<String, String> _chatTitles = {};
  final Set<String> _seenMessageIds = {};

  void Function(String message, {String level})? onLog;
  void Function(MaxIncomingMessage message)? onIncoming;

  bool get isConnected => _socket != null && _loggedIn;

  Map<String, String> get chatTitles => Map.unmodifiable(_chatTitles);

  Future<void> connect({
    required String token,
    required String deviceId,
    int? viewerId,
    List<String> targetChats = const [],
    String? proxyUrl,
  }) async {
    if (_activeToken == token && _loggedIn && _socket != null) {
      _targetChats = targetChats;
      _log('[WS] Уже подключён');
      return;
    }

    await disconnect();
    _activeToken = token;
    _viewerId = viewerId;
    _targetChats = targetChats;
    _seenMessageIds.clear();

    final proxy = proxyUrl?.trim();
    if (proxy == null || proxy.isEmpty) {
      _log('[WS] Подключение к $_wsUrl…');
    } else {
      try {
        final parsed = ParsedProxy.tryParse(proxy)!;
        _log('[WS] Подключение к $_wsUrl через ${parsed.isSocks ? 'SOCKS5' : 'HTTP'} ${parsed.masked}…');
      } catch (_) {
        _log('[WS] Подключение к $_wsUrl через прокси…');
      }
    }
    try {
      _socket = await openProxiedWebSocket(
        _wsUrl,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
          'Origin': 'https://web.max.ru',
        },
        proxyUrl: proxy,
      );
    } on SocketException catch (e) {
      _log('[WS] ✗ Нет соединения: $e', level: 'error');
      rethrow;
    }

    _sub = _socket!.listen(
      _onRawMessage,
      onError: (Object e) => _log('[WS] Ошибка сокета: $e', level: 'error'),
      onDone: () {
        _log('[WS] Соединение закрыто', level: 'warn');
        _loggedIn = false;
        notifyListeners();
      },
    );

    await _invoke(_helloOpcode, {
      'userAgent': {
        'deviceType': 'WEB',
        'locale': 'ru_RU',
        'osVersion': 'Windows',
        'deviceName': 'Chrome',
        'headerUserAgent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
        'deviceLocale': 'ru-RU',
        'appVersion': '25.10.3',
        'screen': '1280x720 1.0x',
        'timezone': 'Europe/Moscow',
      },
      'deviceId': deviceId,
    });
    _log('[WS] Hello отправлен');

    final login = await _invoke(_loginOpcode, {
      'interactive': true,
      'token': token,
      'chatsSync': 0,
      'contactsSync': 0,
      'presenceSync': 0,
      'draftsSync': 0,
      'chatsCount': 40,
    });

    final payload = login['payload'];
    if (payload is Map && payload['error'] != null) {
      throw StateError('Ошибка входа: ${payload['error']}');
    }

    if (_viewerId == null && payload is Map) {
      _viewerId = _asInt(payload['profile']?['contact']?['id'] ?? payload['profile']?['id']);
    }

    _indexChatsFromPayload(payload);
    _loggedIn = true;
    _startKeepalive();

    _log('[WS] ✓ Вход выполнен, viewerId=$_viewerId, чатов: ${_chatTitles.length}');
    if (_chatTitles.isNotEmpty) {
      _log('[WS] Чаты: ${_chatTitles.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _keepalive?.cancel();
    _keepalive = null;
    await _sub?.cancel();
    _sub = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('WS disconnected'));
      }
    }
    _pending.clear();
    await _socket?.close();
    _socket = null;
    _loggedIn = false;
    _activeToken = null;
    notifyListeners();
  }

  Future<void> sendMessage(String chatId, String text) async {
    if (!_loggedIn || _socket == null) {
      throw StateError('WS не подключён');
    }
    final parsed = parseMessageWithLinks(text);
    final preview = parsed.text.length > 60 ? '${parsed.text.substring(0, 60)}…' : parsed.text;
    _log(
      '[WS] → отправка в чат $chatId: $preview'
      '${parsed.elements.isEmpty ? '' : ' (${parsed.elements.length} ссыл.)'}',
    );
    await _invoke(_sendMessageOpcode, {
      'chatId': int.tryParse(chatId) ?? chatId,
      'message': {
        'text': parsed.text,
        'cid': _randomCid(),
        'elements': parsed.elements,
        'attaches': <dynamic>[],
      },
      'notify': true,
    });
    _log('[WS] ✓ Сообщение отправлено');
  }

  String? resolveChatIdForTarget(String target) {
    final t = target.toLowerCase().trim();
    for (final entry in _chatTitles.entries) {
      final title = entry.value.toLowerCase();
      if (title.contains(t) || t.contains(title)) return entry.key;
    }
    return null;
  }

  String? chatTitleFor(String chatId) => _chatTitles[chatId];

  bool matchesTargetChat(String chatId) {
    if (_targetChats.isEmpty) return true;
    final title = (_chatTitles[chatId] ?? '').toLowerCase();
    if (title.isEmpty) return true;
    return _targetChats.any((t) {
      final target = t.toLowerCase().trim();
      return title.contains(target) || target.contains(title);
    });
  }

  Future<void> sendToTargetChat(String target, String text) async {
    final chatId = resolveChatIdForTarget(target);
    if (chatId == null) {
      throw StateError('Чат «$target» не найден. Дождитесь синхронизации или откройте чат в MAX.');
    }
    await sendMessage(chatId, text);
  }

  void _onRawMessage(dynamic data) {
    try {
      final packet = jsonDecode(data as String) as Map<String, dynamic>;
      final seq = _asInt(packet['seq']);
      if (seq != null && _pending.containsKey(seq)) {
        _pending.remove(seq)!.complete(packet);
        return;
      }
      _handleEvent(packet);
    } catch (e) {
      _log('[WS] Ошибка разбора пакета: $e', level: 'error');
    }
  }

  void _handleEvent(Map<String, dynamic> packet) {
    final opcode = _asInt(packet['opcode']);
    final payload = packet['payload'];
    if (payload is Map<String, dynamic>) {
      _indexChatsFromPayload(payload);
    }

    if (opcode != _messageReceivedOpcode || payload is! Map<String, dynamic>) return;

    final message = payload['message'];
    if (message is! Map<String, dynamic>) return;

    final text = message['text']?.toString().trim() ?? '';
    if (text.isEmpty) return;

    final sender = _asInt(message['sender']);
    if (_viewerId != null && sender == _viewerId) {
      _log('[WS] ← своё сообщение, пропуск');
      return;
    }

    final chatId = payload['chatId']?.toString() ?? '';
    final messageId = message['id']?.toString() ?? '';
    if (messageId.isNotEmpty && _seenMessageIds.contains(messageId)) return;

    if (!matchesTargetChat(chatId)) {
      final title = _chatTitles[chatId] ?? chatId;
      _log('[WS] ← пропуск: чат «$title» не в целях [${_targetChats.join(', ')}]', level: 'warn');
      return;
    }

    if (messageId.isNotEmpty) _seenMessageIds.add(messageId);

    final preview = text.length > 50 ? '${text.substring(0, 50)}…' : text;
    final chatTitle = _chatTitles[chatId];
    _log('[WS] ← входящее в «${chatTitle ?? chatId}»: «$preview» (sender=$sender)');

    onIncoming?.call(
      MaxIncomingMessage(
        messageId: messageId,
        chatId: chatId,
        text: text,
        chatTitle: chatTitle,
        sender: sender,
      ),
    );
  }

  void _indexChatsFromPayload(dynamic payload) {
    if (payload is! Map) return;

    final chats = payload['chats'];
    if (chats is List) {
      for (final chat in chats) {
        _registerChat(chat);
      }
    }

    final chat = payload['chat'];
    if (chat is Map) _registerChat(chat);

    final chatList = payload['chatList'];
    if (chatList is List) {
      for (final item in chatList) {
        _registerChat(item);
      }
    }
  }

  void _registerChat(dynamic chat) {
    if (chat is! Map) return;
    final id = chat['id'] ?? chat['chatId'];
    if (id == null) return;

    String? title = chat['title']?.toString();
    title ??= chat['name']?.toString();

    final contact = chat['contact'];
    if (title == null && contact is Map) {
      final names = contact['names'];
      if (names is List && names.isNotEmpty) {
        title = names.first['name']?.toString();
      }
      title ??= contact['name']?.toString();
    }

    if (title != null && title.isNotEmpty) {
      final idStr = id.toString();
      if (_chatTitles[idStr] != title) {
        _log('[WS] Чат: $idStr = «$title»');
      }
      _chatTitles[idStr] = title;
    }
  }

  Future<Map<String, dynamic>> _invoke(int opcode, Map<String, dynamic> payload) async {
    final socket = _socket;
    if (socket == null) throw StateError('WS не подключён');

    final seq = _seq++;
    final request = {
      'ver': _rpcVersion,
      'cmd': 0,
      'seq': seq,
      'opcode': opcode,
      'payload': payload,
    };

    final completer = Completer<Map<String, dynamic>>();
    _pending[seq] = completer;
    socket.add(jsonEncode(request));

    try {
      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pending.remove(seq);
          throw TimeoutException('WS timeout opcode $opcode');
        },
      );
    } catch (e) {
      _pending.remove(seq);
      rethrow;
    }
  }

  void _startKeepalive() {
    _keepalive?.cancel();
    _keepalive = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_loggedIn || _socket == null) return;
      try {
        await _invoke(_keepaliveOpcode, {'interactive': false});
      } catch (e) {
        _log('[WS] Keepalive ошибка: $e', level: 'warn');
      }
    });
  }

  int _randomCid() {
    const base = 1750000000000;
    const max = 2000000000000;
    return base + (Random().nextDouble() * (max - base)).floor();
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  void _log(String message, {String level = 'info'}) {
    onLog?.call(message, level: level);
  }

  @override
  void dispose() {
    unawaited(disconnect());
    super.dispose();
  }
}
