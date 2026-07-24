import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/join_message_template.dart';
import '../models/map_workflow.dart';
import '../providers/app_state.dart';
import '../services/desktop_file_picker.dart';

/// Inline chat-style editor for a [JoinMessageTemplate] (text, photo, pauses).
/// Auto-saves to [AppState] after edits.
class JoinTemplateChatEditor extends StatefulWidget {
  const JoinTemplateChatEditor({
    super.key,
    required this.templateId,
    this.showHeader = true,
  });

  final String templateId;
  final bool showHeader;

  @override
  State<JoinTemplateChatEditor> createState() => _JoinTemplateChatEditorState();
}

class _JoinTemplateChatEditorState extends State<JoinTemplateChatEditor> {
  final _drafts = <_BubbleDraft>[];
  final _composerCtrl = TextEditingController();
  final _scroll = ScrollController();
  String? _composerMedia;
  String? _loadedTemplateId;
  int _loadedRevision = 0;
  Timer? _saveTimer;
  bool _dirty = false;
  bool _saving = false;

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty) {
      // Best-effort sync on dispose via unawaited fire-and-forget is risky;
      // persist synchronously through the last scheduled state if possible.
    }
    _composerCtrl.dispose();
    _scroll.dispose();
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  JoinMessageTemplate? _template(AppState state) =>
      state.joinMessageTemplateById(widget.templateId);

  void _syncFromTemplate(JoinMessageTemplate template, {required bool force}) {
    final rev = Object.hashAll([
      template.id,
      template.messages.length,
      for (final m in template.messages)
        Object.hash(m.id, m.text, m.mediaPath, m.delayAfterMs),
    ]);
    if (!force && _loadedTemplateId == template.id && _loadedRevision == rev && !_dirty) {
      return;
    }
    if (_dirty && !force && _loadedTemplateId == template.id) return;

    for (final d in _drafts) {
      d.dispose();
    }
    _drafts.clear();
    for (final m in template.messages) {
      if (!m.hasContent) continue;
      _drafts.add(
        _BubbleDraft(
          id: m.id,
          text: TextEditingController(text: m.text),
          mediaPath: m.mediaPath,
          delayAfterMs: m.delayAfterMs,
        ),
      );
    }
    _loadedTemplateId = template.id;
    _loadedRevision = rev;
    _dirty = false;
  }

  void _markDirty() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), _persist);
    setState(() {});
  }

  List<BroadcastMessageStep> _collectMessages() {
    return [
      for (final d in _drafts)
        if (d.text.text.trim().isNotEmpty ||
            (d.mediaPath != null && d.mediaPath!.trim().isNotEmpty))
          BroadcastMessageStep(
            id: d.id,
            text: d.text.text.trim(),
            delayAfterMs: d.delayAfterMs,
            mediaPath: d.mediaPath,
          ),
    ];
  }

  Future<void> _persist() async {
    if (!mounted || _saving) return;
    final state = context.read<AppState>();
    final template = _template(state);
    if (template == null) return;

    // Flush pending composer into drafts before save.
    final pendingText = _composerCtrl.text.trim();
    final pendingMedia = _composerMedia?.trim();
    if (pendingText.isNotEmpty ||
        (pendingMedia != null && pendingMedia.isNotEmpty)) {
      _drafts.add(
        _BubbleDraft(
          id: const Uuid().v4(),
          text: TextEditingController(text: pendingText),
          mediaPath: pendingMedia,
        ),
      );
      _composerCtrl.clear();
      _composerMedia = null;
    }

    _saving = true;
    final messages = _collectMessages();
    try {
      await state.updateJoinMessageTemplate(template.copyWith(messages: messages));
      if (!mounted) return;
      _dirty = false;
      _loadedRevision = Object.hashAll([
        template.id,
        messages.length,
        for (final m in messages) Object.hash(m.id, m.text, m.mediaPath, m.delayAfterMs),
      ]);
    } finally {
      _saving = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickComposerPhoto() async {
    final path = await DesktopFilePicker.pickImage(title: 'Фото к сообщению');
    if (path != null && mounted) {
      setState(() => _composerMedia = path);
    }
  }

  Future<void> _pickBubblePhoto(int index) async {
    final path = await DesktopFilePicker.pickImage(title: 'Фото к сообщению');
    if (path != null && mounted) {
      setState(() => _drafts[index].mediaPath = path);
      _markDirty();
    }
  }

  void _addFromComposer() {
    final text = _composerCtrl.text.trim();
    final media = _composerMedia?.trim();
    if (text.isEmpty && (media == null || media.isEmpty)) return;
    setState(() {
      _drafts.add(
        _BubbleDraft(
          id: const Uuid().v4(),
          text: TextEditingController(text: text),
          mediaPath: media,
        ),
      );
      _composerCtrl.clear();
      _composerMedia = null;
    });
    _markDirty();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final template = _template(state);
    if (template == null) {
      return const Center(
        child: Text('Шаблон не найден', style: TextStyle(color: Colors.white54)),
      );
    }

    if (_loadedTemplateId != template.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _syncFromTemplate(template, force: true));
      });
    } else if (!_dirty) {
      _syncFromTemplate(template, force: false);
    }

    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = scheme.primaryContainer.withValues(alpha: 0.55);
    final composerReady = _composerCtrl.text.trim().isNotEmpty ||
        (_composerMedia != null && _composerMedia!.trim().isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: [
                Text(
                  'Чат шаблона · ${_drafts.length} сообщ.',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (_dirty || _saving)
                  Text(
                    _saving ? 'Сохранение…' : 'Не сохранено',
                    style: TextStyle(
                      fontSize: 11,
                      color: _saving ? scheme.primary : scheme.tertiary,
                    ),
                  )
                else
                  Text(
                    'Сохранено',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        Text(
          'Ссылка: [текст](https://…) · канал воронки: {channel_link}',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: _drafts.isEmpty
                ? Center(
                    child: Text(
                      'Пока пусто — напишите ниже\nи добавьте фото при желании',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                    itemCount: _drafts.length,
                    itemBuilder: (context, index) {
                      final d = _drafts[index];
                      final media = d.mediaPath;
                      final mediaOk = media != null && File(media).existsSync();
                      return Align(
                        alignment: Alignment.centerRight,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                            decoration: BoxDecoration(
                              color: bubbleColor,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(14),
                                topRight: Radius.circular(14),
                                bottomLeft: Radius.circular(14),
                                bottomRight: Radius.circular(4),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'Сообщение ${index + 1}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: scheme.onPrimaryContainer
                                            .withValues(alpha: 0.7),
                                      ),
                                    ),
                                    const Spacer(),
                                    SizedBox(
                                      width: 72,
                                      child: _BubbleDelayField(
                                        key: ValueKey('delay-${d.id}'),
                                        delayAfterMs: d.delayAfterMs,
                                        onCommit: (ms) {
                                          d.delayAfterMs = ms;
                                          _markDirty();
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Фото',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () => _pickBubblePhoto(index),
                                      icon: const Icon(Icons.photo_outlined, size: 16),
                                    ),
                                    IconButton(
                                      tooltip: 'Удалить',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () {
                                        setState(() {
                                          _drafts.removeAt(index).dispose();
                                        });
                                        _markDirty();
                                      },
                                      icon: const Icon(Icons.close, size: 16),
                                    ),
                                  ],
                                ),
                                if (mediaOk)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6, top: 4),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Stack(
                                        children: [
                                          Image.file(
                                            File(media),
                                            height: 160,
                                            width: double.infinity,
                                            fit: BoxFit.cover,
                                          ),
                                          Positioned(
                                            top: 4,
                                            right: 4,
                                            child: Material(
                                              color: Colors.black54,
                                              shape: const CircleBorder(),
                                              child: InkWell(
                                                customBorder: const CircleBorder(),
                                                onTap: () {
                                                  setState(() => d.mediaPath = null);
                                                  _markDirty();
                                                },
                                                child: const Padding(
                                                  padding: EdgeInsets.all(4),
                                                  child: Icon(
                                                    Icons.close,
                                                    size: 14,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                else if (media != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text(
                                      'Файл не найден',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: scheme.error,
                                      ),
                                    ),
                                  ),
                                TextField(
                                  controller: d.text,
                                  minLines: 1,
                                  maxLines: 8,
                                  style: const TextStyle(fontSize: 14),
                                  onChanged: (_) => _markDirty(),
                                  decoration: const InputDecoration(
                                    hintText: 'Текст сообщения…',
                                    isDense: true,
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 8),
        if (_composerMedia != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(_composerMedia!),
                    height: 80,
                    width: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 80,
                      width: 80,
                      color: scheme.errorContainer,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _composerMedia = null),
                      child: const Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(Icons.close, size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Прикрепить фото',
              onPressed: _pickComposerPhoto,
              icon: Icon(
                Icons.photo_outlined,
                color: _composerMedia != null
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: TextField(
                controller: _composerCtrl,
                minLines: 1,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _addFromComposer(),
                decoration: const InputDecoration(
                  hintText: 'Новое сообщение…',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              tooltip: 'Добавить в чат',
              onPressed: composerReady ? _addFromComposer : null,
              icon: const Icon(Icons.send_rounded, size: 18),
            ),
          ],
        ),
      ],
    );
  }
}

class _BubbleDraft {
  _BubbleDraft({
    required this.id,
    required this.text,
    this.mediaPath,
    this.delayAfterMs = 3000,
  });

  final String id;
  final TextEditingController text;
  String? mediaPath;
  int delayAfterMs;

  void dispose() => text.dispose();
}

class _BubbleDelayField extends StatefulWidget {
  const _BubbleDelayField({
    super.key,
    required this.delayAfterMs,
    required this.onCommit,
  });

  final int delayAfterMs;
  final ValueChanged<int> onCommit;

  @override
  State<_BubbleDelayField> createState() => _BubbleDelayFieldState();
}

class _BubbleDelayFieldState extends State<_BubbleDelayField> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  static String _fmt(int ms) =>
      (ms / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1);

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _fmt(widget.delayAfterMs));
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _BubbleDelayField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.delayAfterMs != widget.delayAfterMs && !_focus.hasFocus) {
      _ctrl.text = _fmt(widget.delayAfterMs);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final sec = double.tryParse(_ctrl.text.trim().replaceAll(',', '.'));
    if (sec == null) {
      _ctrl.text = _fmt(widget.delayAfterMs);
      return;
    }
    final next = (sec * 1000).round().clamp(0, 600000);
    _ctrl.text = _fmt(next);
    if (next == widget.delayAfterMs) return;
    widget.onCommit(next);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      style: const TextStyle(fontSize: 11),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        isDense: true,
        labelText: 'пауза',
        labelStyle: TextStyle(fontSize: 10),
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      ),
      onEditingComplete: _commit,
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) {
        _commit();
        _focus.unfocus();
      },
    );
  }
}
