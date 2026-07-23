import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/pipeline_journal_event.dart';
import '../providers/app_state.dart';
import 'active_actions_panel.dart';

/// Pipeline journal + live actions in one place.
class PipelineJournalPanel extends StatefulWidget {
  const PipelineJournalPanel({super.key});

  @override
  State<PipelineJournalPanel> createState() => _PipelineJournalPanelState();
}

class _PipelineJournalPanelState extends State<PipelineJournalPanel> {
  int _tab = 0;

  String _fmt(DateTime at) {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    final s = at.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  IconData _icon(PipelineJournalKind kind) => switch (kind) {
        PipelineJournalKind.assign => Icons.bookmark_add_outlined,
        PipelineJournalKind.unassign => Icons.bookmark_remove_outlined,
        PipelineJournalKind.launchPlan => Icons.playlist_play,
        PipelineJournalKind.joinLink => Icons.link,
        PipelineJournalKind.joinById => Icons.person_add_alt_1,
        PipelineJournalKind.templateOnJoin => Icons.mail_outline,
        PipelineJournalKind.templateDaily => Icons.schedule,
        PipelineJournalKind.funnel => Icons.filter_alt_outlined,
        PipelineJournalKind.warn => Icons.warning_amber_outlined,
        PipelineJournalKind.error => Icons.error_outline,
        PipelineJournalKind.info => Icons.info_outline,
      };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final events = state.pipelineJournal;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Журнал',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              if (_tab == 0)
                TextButton(
                  onPressed: events.isEmpty ? null : () => state.clearPipelineJournal(),
                  child: const Text('Очистить'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: [
              const ButtonSegment(value: 0, label: Text('Конвейер'), icon: Icon(Icons.history, size: 16)),
              ButtonSegment(
                value: 1,
                label: const Text('Действия'),
                icon: Badge(
                  isLabelVisible: state.runningActionsCount > 0,
                  label: Text('${state.runningActionsCount}'),
                  child: const Icon(Icons.pending_actions, size: 16),
                ),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _tab == 1
              ? const ActiveActionsPanel(key: ValueKey('pipeline-actions'))
              : events.isEmpty
                  ? Center(
                      child: Text(
                        'Пока пусто — назначения и запуски появятся здесь',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      itemCount: events.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final e = events[i];
                        final mother = e.motherAccountId != null
                            ? state.accountById(e.motherAccountId!)?.label
                            : null;
                        final child = e.childAccountId != null
                            ? state.accountById(e.childAccountId!)?.label
                            : null;
                        return ListTile(
                          dense: true,
                          leading: Icon(_icon(e.kind), size: 20),
                          title: Text(e.message, style: const TextStyle(fontSize: 13)),
                          subtitle: Text(
                            [
                              _fmt(e.at),
                              e.kind.label,
                              if (mother != null) 'матка: $mother',
                              if (child != null) 'дочь: $child',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11),
                          ),
                          isThreeLine: e.detail != null && e.detail!.isNotEmpty,
                          trailing: e.detail == null || e.detail!.isEmpty
                              ? null
                              : Tooltip(
                                  message: e.detail!,
                                  child: const Icon(Icons.notes, size: 16),
                                ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
