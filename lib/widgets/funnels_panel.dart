import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account_map_state.dart';
import '../models/channel_funnel.dart';
import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/desktop_file_picker.dart';

/// Settings: create funnels and assign channel-creation + funnels to accounts.
class FunnelsPanel extends StatefulWidget {
  const FunnelsPanel({super.key});

  @override
  State<FunnelsPanel> createState() => _FunnelsPanelState();
}

class _FunnelsPanelState extends State<FunnelsPanel> {
  int _tabIndex = 0;
  String? _selectedFunnelId;

  void _ensureSelectedFunnel(AppState state) {
    final funnels = state.channelFunnels;
    if (funnels.isEmpty) {
      if (_selectedFunnelId != null) _selectedFunnelId = null;
      return;
    }
    if (_selectedFunnelId == null || !funnels.any((f) => f.id == _selectedFunnelId)) {
      _selectedFunnelId = funnels.first.id;
    }
  }

  Future<void> _addFunnel() async {
    final state = context.read<AppState>();
    final funnel = await state.addChannelFunnel();
    if (!mounted) return;
    setState(() => _selectedFunnelId = funnel.id);
  }

  Future<void> _deleteSelectedFunnel() async {
    final funnelId = _selectedFunnelId;
    if (funnelId == null) return;
    final state = context.read<AppState>();
    final funnel = state.channelFunnelById(funnelId);
    if (funnel == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить воронку?'),
        content: Text('«${funnel.name}» будет удалена у всех аккаунтов.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await state.removeChannelFunnel(funnelId);
    if (!mounted) return;
    setState(() {
      _selectedFunnelId = state.channelFunnels.isNotEmpty ? state.channelFunnels.first.id : null;
    });
  }

  Future<void> _renameSelectedFunnel() async {
    final funnelId = _selectedFunnelId;
    if (funnelId == null) return;
    final state = context.read<AppState>();
    final funnel = state.channelFunnelById(funnelId);
    if (funnel == null) return;
    final nameCtrl = TextEditingController(text: funnel.name);
    final descCtrl = TextEditingController(text: funnel.description ?? '');
    final result = await showDialog<({String name, String? description})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Воронка'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Название воронки',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Заметка (необязательно)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final desc = descCtrl.text.trim();
              Navigator.pop(ctx, (
                name: name,
                description: desc.isEmpty ? null : desc,
              ));
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    descCtrl.dispose();
    if (result == null || !mounted) return;
    await state.updateChannelFunnel(
      funnel.copyWith(
        name: result.name,
        description: result.description,
        clearDescription: result.description == null,
      ),
    );
  }

  Future<void> _editChannelTemplate(ChannelFunnel funnel) async {
    final titleCtrl = TextEditingController(text: funnel.channelTitle);
    final aboutCtrl = TextEditingController(text: funnel.channelDescription ?? '');
    var photoPath = funnel.channelPhotoPath;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final photoExists = photoPath != null && File(photoPath!).existsSync();
          return AlertDialog(
            title: const Text('Шаблон канала'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Название канала',
                        hintText: 'Канал {account}',
                        border: OutlineInputBorder(),
                        helperText: '{account} · {n} · {cluster} · {date}',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: aboutCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Описание канала',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text('Фото канала', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            width: 72,
                            height: 72,
                            color: Colors.white12,
                            child: photoExists
                                ? Image.file(File(photoPath!), fit: BoxFit.cover)
                                : const Icon(Icons.photo_outlined, color: Colors.white38),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () async {
                                  try {
                                    final path = await DesktopFilePicker.pickImage();
                                    if (path == null) return;
                                    setLocal(() => photoPath = path);
                                  } catch (e) {
                                    if (ctx.mounted) {
                                      ScaffoldMessenger.of(ctx).showSnackBar(
                                        SnackBar(content: Text('Не удалось выбрать файл: $e')),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.folder_open, size: 16),
                                label: const Text('Выбрать фото'),
                              ),
                              if (photoPath != null)
                                TextButton(
                                  onPressed: () => setLocal(() => photoPath = null),
                                  child: const Text('Убрать фото'),
                                ),
                              if (photoPath != null)
                                Text(
                                  photoPath!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10, color: Colors.white54),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      ),
    );

    final title = titleCtrl.text.trim();
    final about = aboutCtrl.text.trim();
    titleCtrl.dispose();
    aboutCtrl.dispose();
    if (saved != true || !mounted) return;
    if (title.isEmpty) return;

    await context.read<AppState>().updateChannelFunnel(
          funnel.copyWith(
            channelTitle: title,
            channelDescription: about.isEmpty ? null : about,
            channelPhotoPath: photoPath,
            clearChannelDescription: about.isEmpty,
            clearChannelPhoto: photoPath == null || photoPath!.trim().isEmpty,
          ),
        );
  }

  Future<void> _addStep(ChannelFunnel funnel) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый этап'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название этапа',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty || !mounted) return;
    final state = context.read<AppState>();
    await state.updateChannelFunnel(
      funnel.copyWith(steps: [...funnel.steps, FunnelStep.create(title: title)]),
    );
  }

  Future<void> _editStep(ChannelFunnel funnel, FunnelStep step) async {
    final titleCtrl = TextEditingController(text: step.title);
    final noteCtrl = TextEditingController(text: step.note ?? '');
    final result = await showDialog<({String title, String? note})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Этап'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Заметка',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final title = titleCtrl.text.trim();
              if (title.isEmpty) return;
              final note = noteCtrl.text.trim();
              Navigator.pop(ctx, (title: title, note: note.isEmpty ? null : note));
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    titleCtrl.dispose();
    noteCtrl.dispose();
    if (result == null || !mounted) return;
    final steps = funnel.steps
        .map(
          (s) => s.id == step.id
              ? s.copyWith(title: result.title, note: result.note, clearNote: result.note == null)
              : s,
        )
        .toList();
    await context.read<AppState>().updateChannelFunnel(funnel.copyWith(steps: steps));
  }

  Future<void> _removeStep(ChannelFunnel funnel, FunnelStep step) async {
    final steps = funnel.steps.where((s) => s.id != step.id).toList();
    await context.read<AppState>().updateChannelFunnel(funnel.copyWith(steps: steps));
  }

  Future<void> _reorderSteps(ChannelFunnel funnel, int oldIndex, int newIndex) async {
    final steps = [...funnel.steps];
    final item = steps.removeAt(oldIndex);
    steps.insert(newIndex, item);
    await context.read<AppState>().updateChannelFunnel(funnel.copyWith(steps: steps));
  }

  Future<void> _applyFunnelToClusterChildren(MotherCluster cluster) async {
    final funnelId = _selectedFunnelId;
    if (funnelId == null) return;
    final ids = <String>{
      if (cluster.motherAccountId != null) cluster.motherAccountId!,
      ...cluster.childAccountIds,
    };
    if (ids.isEmpty) return;
    await context.read<AppState>().applyFunnelToAccounts(
          funnelId: funnelId,
          accountIds: ids,
          canCreateChannels: true,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Воронка назначена ${ids.length} акк. кластера «${cluster.name}» '
          '(создание каналов включено)',
        ),
      ),
    );
  }

  Future<void> _editPublications(ChannelFunnel funnel) async {
    var posts = [...funnel.publications];
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Публикации'),
          content: SizedBox(
            width: 440,
            height: 420,
            child: Column(
              children: [
                Expanded(
                  child: posts.isEmpty
                      ? const Center(
                          child: Text(
                            'Нет постов. Добавьте текст публикации.',
                            style: TextStyle(color: Colors.white60),
                          ),
                        )
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: posts.length,
                          onReorderItem: (oldIndex, newIndex) {
                            setLocal(() {
                              final item = posts.removeAt(oldIndex);
                              posts.insert(newIndex, item);
                            });
                          },
                          itemBuilder: (context, index) {
                            final post = posts[index];
                            return ListTile(
                              key: ValueKey(post.id),
                              dense: true,
                              leading: ReorderableDragStartListener(
                                index: index,
                                child: CircleAvatar(
                                  radius: 12,
                                  child: Text('${index + 1}', style: const TextStyle(fontSize: 10)),
                                ),
                              ),
                              title: Text(
                                post.text.trim().isEmpty ? '(пустой пост)' : post.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              subtitle: Text(
                                'пауза ${(post.delayAfterMs / 1000).toStringAsFixed(post.delayAfterMs % 1000 == 0 ? 0 : 1)}с'
                                '${post.mediaPath != null ? ' · фото' : ''}',
                                style: const TextStyle(fontSize: 10),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                onPressed: () async {
                                  final edited = await _promptPublication(post);
                                  if (edited == null) return;
                                  setLocal(() => posts[index] = edited);
                                },
                              ),
                              onTap: () async {
                                final edited = await _promptPublication(post);
                                if (edited == null) return;
                                setLocal(() => posts[index] = edited);
                              },
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        final created = await _promptPublication(
                          FunnelPublication.create(text: ''),
                        );
                        if (created == null) return;
                        setLocal(() => posts = [...posts, created]);
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Пост'),
                    ),
                    const Spacer(),
                    if (posts.isNotEmpty)
                      TextButton(
                        onPressed: () => setLocal(() => posts = posts.sublist(0, posts.length - 1)),
                        child: const Text('Удалить последний'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    await context.read<AppState>().updateChannelFunnel(funnel.copyWith(publications: posts));
  }

  Future<FunnelPublication?> _promptPublication(FunnelPublication post) async {
    final textCtrl = TextEditingController(text: post.text);
    final delayCtrl = TextEditingController(
      text: (post.delayAfterMs / 1000).toStringAsFixed(post.delayAfterMs % 1000 == 0 ? 0 : 1),
    );
    var mediaPath = post.mediaPath;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Пост'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: textCtrl,
                  maxLines: 4,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Текст',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                    helperText:
                        '{account} · {channel_link} · Ссылка: [МОЙ КАНАЛ]({channel_link})',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: delayCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Пауза после поста (сек)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        mediaPath == null ? 'Без фото' : mediaPath!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Colors.white60),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final path = await DesktopFilePicker.pickImage(title: 'Фото к посту');
                        if (path != null) setLocal(() => mediaPath = path);
                      },
                      child: const Text('Фото'),
                    ),
                    if (mediaPath != null)
                      IconButton(
                        onPressed: () => setLocal(() => mediaPath = null),
                        icon: const Icon(Icons.close, size: 16),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
          ],
        ),
      ),
    );
    final text = textCtrl.text;
    final delaySec = double.tryParse(delayCtrl.text.trim().replaceAll(',', '.')) ?? 3;
    textCtrl.dispose();
    delayCtrl.dispose();
    if (ok != true) return null;
    return post.copyWith(
      text: text,
      delayAfterMs: (delaySec * 1000).round().clamp(0, 120000),
      mediaPath: mediaPath,
      clearMedia: mediaPath == null,
    );
  }

  Future<void> _editRunSettings(ChannelFunnel funnel) async {
    var privateChannel = funnel.privateChannel;
    var commentsEnabled = funnel.commentsEnabled;
    var publishAfterCreate = funnel.publishAfterCreate;
    final gapCtrl = TextEditingController(
      text: (funnel.accountGapMs / 1000).toStringAsFixed(funnel.accountGapMs % 1000 == 0 ? 0 : 1),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Настройки канала / запуска'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Публиковать посты после создания', style: TextStyle(fontSize: 13)),
                  value: publishAfterCreate,
                  onChanged: (v) => setLocal(() => publishAfterCreate = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Приватный канал (invite)', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Если API поддержит — предпочтение private link', style: TextStyle(fontSize: 11)),
                  value: privateChannel,
                  onChanged: (v) => setLocal(() => privateChannel = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Комментарии', style: TextStyle(fontSize: 13)),
                  value: commentsEnabled,
                  onChanged: (v) => setLocal(() => commentsEnabled = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: gapCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Пауза между аккаунтами (сек)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
          ],
        ),
      ),
    );
    final gapSec = double.tryParse(gapCtrl.text.trim().replaceAll(',', '.')) ?? 5;
    gapCtrl.dispose();
    if (saved != true || !mounted) return;
    await context.read<AppState>().updateChannelFunnel(
          funnel.copyWith(
            privateChannel: privateChannel,
            commentsEnabled: commentsEnabled,
            publishAfterCreate: publishAfterCreate,
            accountGapMs: (gapSec * 1000).round().clamp(0, 300000),
          ),
        );
  }

  Future<void> _runSelectedFunnel() async {
    final funnelId = _selectedFunnelId;
    if (funnelId == null) return;
    final state = context.read<AppState>();
    final funnel = state.channelFunnelById(funnelId);
    if (funnel == null) return;

    final ready = state.accounts.where((a) {
      final p = state.channelPolicyFor(a.id);
      return p.canCreateChannels && p.funnelIds.contains(funnelId) && a.hasApiSession;
    }).length;

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Запустить воронку?'),
        content: Text(
          '«${funnel.name}»\n'
          'Аккаунтов к запуску: $ready\n'
          'Постов: ${funnel.publicationCount}\n\n'
          'Для каждого аккаунта: создать канал по шаблону'
          '${funnel.publishAfterCreate ? ' и опубликовать посты' : ''}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Запустить')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    final summary = await state.runChannelFunnel(funnelId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(summary.message), duration: const Duration(seconds: 5)),
    );
  }

  Future<void> _publishSelectedFunnel() async {
    final state = context.read<AppState>();
    final funnelId = _selectedFunnelId;
    if (funnelId == null) return;
    final funnel = state.channelFunnelById(funnelId);
    if (funnel == null) return;
    if (funnel.publicationCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('В воронке нет постов')),
      );
      return;
    }

    final candidates = state.accounts.where((a) {
      final p = state.channelPolicyFor(a.id);
      return p.canCreateChannels && p.funnelIds.contains(funnelId) && a.hasApiSession;
    }).toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет аккаунтов воронки с токеном')),
      );
      return;
    }

    final selectedIds = <String>{
      for (final a in candidates)
        if (state.channelPolicyFor(a.id).lastCreatedChatId?.trim().isNotEmpty == true) a.id,
    };

    final go = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final withChannel = candidates.where((a) {
            return state.channelPolicyFor(a.id).lastCreatedChatId?.trim().isNotEmpty == true;
          }).length;
          return AlertDialog(
            title: const Text('Опубликовать посты'),
            content: SizedBox(
              width: 420,
              height: 420,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '«${funnel.name}» · ${funnel.publicationCount} пост.\n'
                    'В уже созданные каналы (без создания новых).\n'
                    'С каналом: $withChannel / ${candidates.length}',
                    style: const TextStyle(fontSize: 12, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setLocal(() {
                          selectedIds
                            ..clear()
                            ..addAll(
                              candidates
                                  .where(
                                    (a) =>
                                        state
                                            .channelPolicyFor(a.id)
                                            .lastCreatedChatId
                                            ?.trim()
                                            .isNotEmpty ==
                                        true,
                                  )
                                  .map((a) => a.id),
                            );
                        }),
                        child: const Text('Все с каналом'),
                      ),
                      TextButton(
                        onPressed: () => setLocal(() => selectedIds.clear()),
                        child: const Text('Снять'),
                      ),
                    ],
                  ),
                  const Divider(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (context, index) {
                        final account = candidates[index];
                        final policy = state.channelPolicyFor(account.id);
                        final chatId = policy.lastCreatedChatId?.trim();
                        final hasChat = chatId != null && chatId.isNotEmpty;
                        final title = policy.lastCreatedTitle?.trim();
                        return CheckboxListTile(
                          dense: true,
                          value: selectedIds.contains(account.id),
                          onChanged: hasChat
                              ? (v) => setLocal(() {
                                    if (v == true) {
                                      selectedIds.add(account.id);
                                    } else {
                                      selectedIds.remove(account.id);
                                    }
                                  })
                              : null,
                          title: Text(
                            account.profileDisplayName,
                            style: const TextStyle(fontSize: 12),
                          ),
                          subtitle: Text(
                            hasChat
                                ? (title?.isNotEmpty == true
                                    ? '$title · $chatId'
                                    : 'канал $chatId')
                                : 'нет созданного канала — сначала запустите воронку',
                            style: TextStyle(
                              fontSize: 10,
                              color: hasChat ? Colors.white60 : Colors.orangeAccent,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
              FilledButton(
                onPressed: selectedIds.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, Set<String>.from(selectedIds)),
                child: Text('Опубликовать (${selectedIds.length})'),
              ),
            ],
          );
        },
      ),
    );
    if (go == null || go.isEmpty || !mounted) return;

    final summary = await state.publishChannelFunnelPosts(funnelId, accountIds: go);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(summary.message), duration: const Duration(seconds: 5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureSelectedFunnel(state);
    final scheme = Theme.of(context).colorScheme;
    final funnel = state.channelFunnelById(_selectedFunnelId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Воронки', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              SizedBox(height: 2),
              Text(
                'Шаблон канала, публикации, настройки и запуск для аккаунтов '
                'с правом «создавать каналы».',
                style: TextStyle(fontSize: 12, color: Colors.white60, height: 1.35),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Воронки'), icon: Icon(Icons.filter_alt_outlined, size: 16)),
              ButtonSegment(value: 1, label: Text('Аккаунты'), icon: Icon(Icons.people_outline, size: 16)),
            ],
            selected: {_tabIndex},
            onSelectionChanged: (v) => setState(() => _tabIndex = v.first),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _tabIndex == 0
              ? _FunnelsTab(
                  state: state,
                  funnels: state.channelFunnels,
                  selectedId: _selectedFunnelId,
                  selected: funnel,
                  running: state.funnelRunning,
                  onSelect: (id) => setState(() => _selectedFunnelId = id),
                  onAdd: _addFunnel,
                  onRename: _renameSelectedFunnel,
                  onDelete: _deleteSelectedFunnel,
                  onEditChannelTemplate:
                      funnel == null ? null : () => _editChannelTemplate(funnel),
                  onEditPublications:
                      funnel == null ? null : () => _editPublications(funnel),
                  onEditRunSettings:
                      funnel == null ? null : () => _editRunSettings(funnel),
                  onRun: funnel == null || state.funnelRunning ? null : _runSelectedFunnel,
                  onPublish:
                      funnel == null || state.funnelRunning ? null : _publishSelectedFunnel,
                  onAddStep: funnel == null ? null : () => _addStep(funnel),
                  onEditStep: funnel == null ? null : (step) => _editStep(funnel, step),
                  onRemoveStep: funnel == null ? null : (step) => _removeStep(funnel, step),
                  onReorder: funnel == null
                      ? null
                      : (oldIndex, newIndex) => _reorderSteps(funnel, oldIndex, newIndex),
                )
              : _AccountsTab(
                  state: state,
                  scheme: scheme,
                  onApplyCluster: _applyFunnelToClusterChildren,
                  selectedFunnelId: _selectedFunnelId,
                ),
        ),
      ],
    );
  }
}

class _FunnelsTab extends StatelessWidget {
  const _FunnelsTab({
    required this.state,
    required this.funnels,
    required this.selectedId,
    required this.selected,
    required this.running,
    required this.onSelect,
    required this.onAdd,
    required this.onRename,
    required this.onDelete,
    required this.onEditChannelTemplate,
    required this.onEditPublications,
    required this.onEditRunSettings,
    required this.onRun,
    required this.onPublish,
    required this.onAddStep,
    required this.onEditStep,
    required this.onRemoveStep,
    required this.onReorder,
  });

  final AppState state;
  final List<ChannelFunnel> funnels;
  final String? selectedId;
  final ChannelFunnel? selected;
  final bool running;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onEditChannelTemplate;
  final VoidCallback? onEditPublications;
  final VoidCallback? onEditRunSettings;
  final VoidCallback? onRun;
  final VoidCallback? onPublish;
  final VoidCallback? onAddStep;
  final Future<void> Function(FunnelStep step)? onEditStep;
  final Future<void> Function(FunnelStep step)? onRemoveStep;
  final ReorderCallback? onReorder;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Воронки (${funnels.length})',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Переименовать',
              onPressed: selected == null ? null : onRename,
              icon: const Icon(Icons.edit, size: 18),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: 'Удалить',
              onPressed: selected == null ? null : onDelete,
              icon: const Icon(Icons.delete_outline, size: 18),
              visualDensity: VisualDensity.compact,
            ),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Добавить', style: TextStyle(fontSize: 11)),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (funnels.isEmpty)
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Пока нет воронок. Создайте первую — задайте название/описание/фото канала '
                    'и назначьте аккаунтам.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.filter_alt_outlined, size: 18),
                    label: const Text('Создать воронку'),
                  ),
                ],
              ),
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final funnel in funnels)
                ChoiceChip(
                  selected: funnel.id == selectedId,
                  label: Text(
                    '${funnel.name} · ${funnel.stepCount}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  avatar: const Icon(Icons.filter_alt_outlined, size: 14),
                  onSelected: (_) => onSelect(funnel.id),
                ),
            ],
          ),
        if (selected != null) ...[
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRun,
            icon: running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(running ? 'Воронка выполняется…' : 'Запустить воронку'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onPublish,
            icon: const Icon(Icons.campaign_outlined, size: 18),
            label: const Text('Опубликовать посты'),
          ),
          const SizedBox(height: 10),
          _FunnelCreatorsCard(
            state: state,
            funnelId: selected!.id,
          ),
          const SizedBox(height: 8),
          _ChannelTemplateCard(
            funnel: selected!,
            onEdit: onEditChannelTemplate,
          ),
          const SizedBox(height: 8),
          _SimpleActionCard(
            icon: Icons.campaign_outlined,
            title: 'Публикации (${selected!.publicationCount})',
            subtitle: selected!.publicationCount == 0
                ? 'Нет постов — добавьте тексты для ленты канала'
                : selected!.publications
                    .take(2)
                    .map((p) => p.text.trim().isEmpty ? '(фото)' : p.text.trim())
                    .join(' · '),
            onTap: onEditPublications,
          ),
          const SizedBox(height: 8),
          _SimpleActionCard(
            icon: Icons.tune,
            title: 'Настройки канала / запуска',
            subtitle:
                '${selected!.publishAfterCreate ? 'посты вкл' : 'посты выкл'} · '
                '${selected!.privateChannel ? 'private' : 'public'} · '
                'пауза ${(selected!.accountGapMs / 1000).toStringAsFixed(selected!.accountGapMs % 1000 == 0 ? 0 : 1)}с',
            onTap: onEditRunSettings,
          ),
          const SizedBox(height: 12),
          if (selected!.description != null && selected!.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                selected!.description!,
                style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.35),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Этапы (${selected!.stepCount})',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: onAddStep,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Этап', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (selected!.steps.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Нет этапов. Добавьте шаги воронки.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: selected!.steps.length,
              onReorderItem: onReorder!,
              itemBuilder: (context, index) {
                final step = selected!.steps[index];
                return Card(
                  key: ValueKey(step.id),
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: CircleAvatar(
                        radius: 14,
                        child: Text('${index + 1}', style: const TextStyle(fontSize: 11)),
                      ),
                    ),
                    title: Text(step.title, style: const TextStyle(fontSize: 13)),
                    subtitle: step.note == null
                        ? null
                        : Text(step.note!, style: const TextStyle(fontSize: 11)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Изменить',
                          onPressed: () => onEditStep?.call(step),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          tooltip: 'Удалить',
                          onPressed: () => onRemoveStep?.call(step),
                          icon: const Icon(Icons.close, size: 18),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ],
    );
  }
}

class _SimpleActionCard extends StatelessWidget {
  const _SimpleActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        dense: true,
        leading: Icon(icon, size: 22),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.white60),
        ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: onTap,
      ),
    );
  }
}

class _FunnelCreatorsCard extends StatelessWidget {
  const _FunnelCreatorsCard({
    required this.state,
    required this.funnelId,
  });

  final AppState state;
  final String funnelId;

  @override
  Widget build(BuildContext context) {
    final creators = state.accounts.where((a) {
      final p = state.channelPolicyFor(a.id);
      return p.canCreateChannels && p.funnelIds.contains(funnelId);
    }).toList();

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Каналы создателей',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              creators.isEmpty
                  ? 'Никого нет — вкладка «Аккаунты»: включите «создавать каналы» и воронку.'
                  : 'В MAX у аккаунта канал появится только после успешного «Создание канала». '
                      'Закрытый id из прошлых запусков — не канал.',
              style: const TextStyle(fontSize: 11, color: Colors.white54, height: 1.35),
            ),
            if (creators.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final account in creators) ...[
                Builder(
                  builder: (context) {
                    final policy = state.channelPolicyFor(account.id);
                    final chatId = policy.lastCreatedChatId;
                    final title = policy.lastCreatedTitle;
                    final invite = policy.lastCreatedInviteUrl;
                    final hasStored = chatId != null;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  account.profileDisplayName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  hasStored
                                      ? 'сохранён id $chatId'
                                          '${title != null && title.isNotEmpty ? ' · $title' : ''}'
                                          '${invite != null && invite.isNotEmpty ? '\n$invite' : ''}'
                                          '\n(если в MAX пусто — id мёртвый, жмите Сбросить)'
                                      : 'канала ещё нет — запустите воронку',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: hasStored
                                        ? Colors.orangeAccent.withValues(alpha: 0.9)
                                        : Colors.white54,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (hasStored)
                            TextButton(
                              onPressed: () => state.clearAccountCreatedChannel(account.id),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                              ),
                              child: const Text('Сбросить', style: TextStyle(fontSize: 11)),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ChannelTemplateCard extends StatelessWidget {
  const _ChannelTemplateCard({
    required this.funnel,
    required this.onEdit,
  });

  final ChannelFunnel funnel;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final photoPath = funnel.channelPhotoPath;
    final photoExists = photoPath != null && File(photoPath).existsSync();
    final about = funnel.channelDescription?.trim();

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 56,
                  height: 56,
                  color: Colors.white12,
                  child: photoExists
                      ? Image.file(File(photoPath), fit: BoxFit.cover)
                      : const Icon(Icons.photo_outlined, color: Colors.white38),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Шаблон канала',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      funnel.channelTitle,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      (about == null || about.isEmpty) ? 'Описание не задано' : about,
                      style: const TextStyle(fontSize: 11, color: Colors.white60, height: 1.3),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      photoExists ? 'Фото выбрано' : 'Без фото',
                      style: TextStyle(
                        fontSize: 10,
                        color: photoExists ? const Color(0xFFA5D6A7) : Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Изменить шаблон',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountsTab extends StatelessWidget {
  const _AccountsTab({
    required this.state,
    required this.scheme,
    required this.onApplyCluster,
    required this.selectedFunnelId,
  });

  final AppState state;
  final ColorScheme scheme;
  final Future<void> Function(MotherCluster cluster) onApplyCluster;
  final String? selectedFunnelId;

  @override
  Widget build(BuildContext context) {
    final accounts = state.accounts;
    final clusters = state.motherClusters;
    final funnels = state.channelFunnels;
    final assignedIds = {
      for (final c in clusters) ...[
        if (c.motherAccountId != null) c.motherAccountId!,
        ...c.childAccountIds,
      ],
    };
    final unassigned = accounts.where((a) => !assignedIds.contains(a.id)).toList();

    if (accounts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Сначала добавьте профили на вкладке «Вход».',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      children: [
        if (funnels.isEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: scheme.errorContainer.withValues(alpha: 0.35),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Создайте хотя бы одну воронку на вкладке «Воронки», '
                'чтобы назначать её аккаунтам.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        Text(
          'Включите «создавать каналы» и отметьте воронки для каждого аккаунта. '
          'Кнопка у матки применяет выбранную воронку ко всему кластеру.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, color: Colors.white60),
        ),
        const SizedBox(height: 12),
        for (final cluster in clusters) ...[
          _ClusterHeader(
            cluster: cluster,
            mother: state.accountById(cluster.motherAccountId),
            canApply: selectedFunnelId != null,
            onApply: () => onApplyCluster(cluster),
          ),
          if (cluster.motherAccountId != null &&
              state.accountById(cluster.motherAccountId!) != null)
            _AccountPolicyTile(
              account: state.accountById(cluster.motherAccountId!)!,
              roleLabel: 'матка',
              funnels: funnels,
              policy: state.channelPolicyFor(cluster.motherAccountId!),
            ),
          for (final childId in cluster.childAccountIds)
            if (state.accountById(childId) != null)
              _AccountPolicyTile(
                account: state.accountById(childId)!,
                roleLabel: 'дочерний',
                funnels: funnels,
                policy: state.channelPolicyFor(childId),
              ),
          if (cluster.motherAccountId == null && cluster.childAccountIds.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                'В кластере пока нет аккаунтов — создайте кластер во вкладке «Раздача».',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
          const SizedBox(height: 10),
        ],
        if (unassigned.isNotEmpty) ...[
          const Text(
            'Без матки',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
          const SizedBox(height: 6),
          for (final account in unassigned)
            _AccountPolicyTile(
              account: account,
              roleLabel: 'аккаунт',
              funnels: funnels,
              policy: state.channelPolicyFor(account.id),
            ),
        ],
      ],
    );
  }
}

class _ClusterHeader extends StatelessWidget {
  const _ClusterHeader({
    required this.cluster,
    required this.mother,
    required this.canApply,
    required this.onApply,
  });

  final MotherCluster cluster;
  final MaxAccount? mother;
  final bool canApply;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          const Icon(Icons.hive_outlined, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${cluster.name}'
              '${mother != null ? ' · ${mother!.profileDisplayName}' : ''}'
              ' · ${cluster.childCount} доч.',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: canApply ? onApply : null,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Назначить кластеру', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _AccountPolicyTile extends StatelessWidget {
  const _AccountPolicyTile({
    required this.account,
    required this.roleLabel,
    required this.funnels,
    required this.policy,
  });

  final MaxAccount account;
  final String roleLabel;
  final List<ChannelFunnel> funnels;
  final AccountChannelPolicy policy;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.profileDisplayName,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        roleLabel,
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                FilterChip(
                  selected: policy.canCreateChannels,
                  label: const Text('создавать каналы', style: TextStyle(fontSize: 11)),
                  avatar: Icon(
                    policy.canCreateChannels ? Icons.add_box : Icons.add_box_outlined,
                    size: 14,
                  ),
                  onSelected: (v) => state.setAccountCanCreateChannels(account.id, v),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (funnels.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final funnel in funnels)
                    FilterChip(
                      selected: policy.funnelIds.contains(funnel.id),
                      label: Text(funnel.name, style: const TextStyle(fontSize: 11)),
                      onSelected: (v) => state.toggleAccountFunnel(account.id, funnel.id, v),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            if (policy.lastCreatedChatId != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Последний канал: ${policy.lastCreatedTitle ?? policy.lastCreatedChatId}'
                      ' (${policy.lastCreatedChatId})',
                      style: const TextStyle(fontSize: 10, color: Colors.white54),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => state.clearAccountCreatedChannel(account.id),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('Сбросить', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
