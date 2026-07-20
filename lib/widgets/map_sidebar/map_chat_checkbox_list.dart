import 'package:flutter/material.dart';

class MapChatCheckboxList extends StatelessWidget {
  const MapChatCheckboxList({
    super.key,
    required this.availableChats,
    required this.selectedChats,
    required this.onChanged,
    this.emptyHint,
  });

  final List<String> availableChats;
  final Set<String> selectedChats;
  final ValueChanged<Set<String>> onChanged;
  final String? emptyHint;

  List<String> get _orphanSelections {
    return selectedChats
        .where((s) => !availableChats.any((a) => a == s))
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  void _toggle(String chat, bool? value) {
    final next = Set<String>.from(selectedChats);
    if (value == true) {
      next.add(chat);
    } else {
      next.remove(chat);
    }
    onChanged(next);
  }

  void _selectAll(bool select) {
    if (select) {
      onChanged({...availableChats, ..._orphanSelections});
    } else {
      onChanged({});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final orphans = _orphanSelections;
    final allSelected = availableChats.isNotEmpty &&
        availableChats.every((c) => selectedChats.contains(c)) &&
        orphans.every((c) => selectedChats.contains(c));

    if (availableChats.isEmpty && orphans.isEmpty) {
      return Text(
        emptyHint ?? 'Список пуст. Нажмите «Загрузить из MAX».',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (availableChats.isNotEmpty)
          Row(
            children: [
              Text(
                'Выбрано: ${selectedChats.length}',
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _selectAll(!allSelected),
                child: Text(allSelected ? 'Снять все' : 'Выбрать все'),
              ),
            ],
          ),
        for (final chat in availableChats)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(chat, style: const TextStyle(fontSize: 13)),
            value: selectedChats.contains(chat),
            onChanged: (v) => _toggle(chat, v),
          ),
        if (orphans.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Ранее сохранённые', style: theme.textTheme.labelSmall),
          for (final chat in orphans)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(chat, style: const TextStyle(fontSize: 13)),
              subtitle: const Text('нет в текущем списке MAX', style: TextStyle(fontSize: 11)),
              value: selectedChats.contains(chat),
              onChanged: (v) => _toggle(chat, v),
            ),
        ],
      ],
    );
  }
}
