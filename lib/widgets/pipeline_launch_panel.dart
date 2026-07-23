import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/active_action.dart';
import '../models/max_channel_catalog_entry.dart';
import '../models/pipeline_journal_event.dart';
import '../providers/app_state.dart';
import '../services/child_post_join_runner.dart';
import '../services/max_mother_service.dart';
import '../services/pipeline_group_planner.dart';

/// Preview unique group distribution and run children join by invite links.
class PipelineLaunchPanel extends StatefulWidget {
  const PipelineLaunchPanel({super.key});

  @override
  State<PipelineLaunchPanel> createState() => _PipelineLaunchPanelState();
}

class _PipelineLaunchPanelState extends State<PipelineLaunchPanel> {
  bool _inviteById = false;
  bool _running = false;
  final _log = <String>[];

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 200) _log.removeLast();
    });
  }

  PipelineLaunchPlan _plan(AppState state) {
    return state.buildPipelineLaunchPlan(
      alreadyJoinedChatIds: state.joinedChatIdsForPipeline(),
    );
  }

  Future<void> _run(AppState state) async {
    if (_running) return;
    final plan = _plan(state);
    if (!plan.ok) {
      _append(plan.error ?? 'План пуст');
      return;
    }

    setState(() {
      _running = true;
      _log.clear();
    });

    await state.addPipelineJournal(
      kind: PipelineJournalKind.launchPlan,
      message: plan.summaryLine,
      detail: _inviteById ? 'режим: по ID' : 'режим: по ссылкам',
    );

    final action = state.beginAction(
      kind: _inviteById ? ActiveActionKind.inviteChildren : ActiveActionKind.childrenJoin,
      title: _inviteById ? 'Запуск: по ID' : 'Запуск: по ссылкам',
      subtitle: plan.summaryLine,
    );

    void track(String msg) {
      _append(msg);
      state.updateActionProgress(action.id, message: msg);
    }

    try {
      if (_inviteById) {
        await _runById(state, plan, action, track);
      } else {
        await _runByLinks(state, plan, action, track);
      }
    } catch (e) {
      track('✗ $e');
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
      await state.addPipelineJournal(
        kind: PipelineJournalKind.error,
        message: 'Запуск упал: $e',
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runByLinks(
    AppState state,
    PipelineLaunchPlan plan,
    ActiveAction action,
    void Function(String) track,
  ) async {
    var doneSlots = 0;
    final allResults = <Map<String, dynamic>>[];

    for (final slot in plan.slots) {
      if (action.cancelToken.isCancelled) break;

      final withLink = slot.groups.where((g) => g.hasInviteLink).toList();
      final skipped = slot.withoutLinkCount;
      if (skipped > 0) {
        track('«${slot.child.label}»: пропуск $skipped без ссылки');
        await state.addPipelineJournal(
          kind: PipelineJournalKind.warn,
          message: '«${slot.child.label}»: $skipped групп без invite-ссылки',
          motherAccountId: slot.mother.id,
          childAccountId: slot.child.id,
        );
      }
      if (withLink.isEmpty) {
        doneSlots++;
        continue;
      }

      track(
        '[${doneSlots + 1}/${plan.slots.length}] «${slot.child.label}» ← ${withLink.length} групп (матка «${slot.mother.label}»)',
      );

      // Compact payload: hashes only (Windows argv limit). Always via args file for large lists.
      final groups = [
        for (final g in withLink)
          {
            'chatId': g.chatId,
            'hash': g.inviteHash,
          },
      ];
      final links = [
        for (final g in withLink)
          if (g.inviteUrl != null) g.inviteUrl!,
      ];
      final childProxy = slot.child.isolation.proxyServer?.trim();
      // Child must use its own proxy (or none) — mother's proxy can block child join.
      final childProxyOrNull =
          (childProxy != null && childProxy.isNotEmpty) ? childProxy : null;

      track('CLI children-join: ${groups.length} хешей…');
      final result = await MaxMotherService.childrenJoin(
        childTokens: [slot.child.apiToken!],
        links: links,
        groups: groups,
        delayMs: state.rateSettings.motherJoinDelayMs,
        proxy: childProxyOrNull,
        childProxies: [childProxyOrNull],
        onProgress: track,
        cancel: action.cancelToken,
      );

      track(
        result.ok
            ? '«${slot.child.label}»: ${result.message}'
            : '✗ «${slot.child.label}»: ${result.message}',
      );

      allResults.addAll(result.results);

      await state.recordMembershipsFromJoinResults(
        motherAccountId: null,
        children: [slot.child],
        results: result.results,
        titleByChatId: {for (final g in withLink) g.chatId: g.title},
      );

      await state.addPipelineJournal(
        kind: PipelineJournalKind.joinLink,
        message: result.joined > 0
            ? '«${slot.child.label}»: вступило ${result.joined}/${withLink.length}'
            : '«${slot.child.label}»: вступило 0/${withLink.length} — ${result.message}',
        motherAccountId: slot.mother.id,
        childAccountId: slot.child.id,
        detail: result.joined > 0
            ? null
            : () {
                final errs = result.results
                    .where((r) => r['ok'] != true && r['error'] != null)
                    .map((r) => r['error'].toString())
                    .take(5)
                    .join(' | ');
                return errs.isEmpty ? null : errs;
              }(),
      );

      // onJoin templates for this child
      final template = state.joinTemplateForAccount(slot.child.id);
      if (template != null && template.isActive && result.joined > 0) {
        track('Письмо после входа: «${template.name}»');
        final channelLinks = await state.ensureChannelInviteLinks(
          [slot.child],
          onLog: (msg, {String level = 'info'}) => track(msg),
          cancel: action.cancelToken,
        );
        await ChildPostJoinRunner.runFromJoinResults(
          tokenChildren: [slot.child],
          joinResults: result.results,
          templateFor: (_) => template,
          channelLinkFor: (child) =>
              channelLinks[child.id] ??
              state.channelPolicyFor(child.id).lastCreatedInviteUrl,
          onLog: (msg, {String level = 'info'}) => track(msg),
          rateSettings: state.rateSettings,
          cancel: action.cancelToken,
        );
        await state.addPipelineJournal(
          kind: PipelineJournalKind.templateOnJoin,
          message: '«${slot.child.label}» написал по шаблону «${template.name}»',
          motherAccountId: slot.mother.id,
          childAccountId: slot.child.id,
        );
      }

      doneSlots++;
      state.updateActionProgress(
        action.id,
        done: doneSlots,
        total: plan.slots.length,
      );
    }

    if (action.cancelToken.isCancelled) {
      state.finishAction(action.id, status: ActiveActionStatus.cancelled);
    } else {
      state.finishAction(
        action.id,
        message: 'Готово: $doneSlots слотов, вступлений: ${allResults.where((r) => r['ok'] == true && r['phase'] == 'child_join').length}',
      );
    }
  }

  Future<void> _runById(
    AppState state,
    PipelineLaunchPlan plan,
    ActiveAction action,
    void Function(String) track,
  ) async {
    final byMother = <String, List<PipelineAssignSlot>>{};
    for (final slot in plan.slots) {
      byMother.putIfAbsent(slot.mother.id, () => []).add(slot);
    }

    var mothersDone = 0;
    for (final entry in byMother.entries) {
      if (action.cancelToken.isCancelled) break;
      final motherSlots = entry.value;
      final mother = motherSlots.first.mother;

      final unique = <String, MaxChannelCatalogEntry>{};
      for (final slot in motherSlots) {
        for (final g in slot.groups) {
          unique[g.chatId] = g;
        }
      }
      final uniqueGroups = unique.values.toList();

      track('Матка «${mother.label}»: вступление в ${uniqueGroups.length} групп…');
      final joinLinks = [
        for (final g in uniqueGroups)
          if (g.hasInviteLink) g.inviteUrl!,
      ];
      if (joinLinks.isEmpty) {
        track('«${mother.label}»: нет ссылок для вступления');
        mothersDone++;
        continue;
      }

      final motherProxy = mother.isolation.proxyServer?.trim();
      final joinResult = await MaxMotherService.joinGroups(
        token: mother.apiToken!,
        links: joinLinks,
        delayMs: state.rateSettings.motherJoinDelayMs,
        proxy: (motherProxy != null && motherProxy.isNotEmpty) ? motherProxy : null,
        onProgress: track,
        cancel: action.cancelToken,
      );

      await state.recordMembershipsFromJoinResults(
        motherAccountId: mother.id,
        children: const [],
        results: joinResult.results,
        titleByChatId: {for (final g in uniqueGroups) g.chatId: g.title},
      );

      for (final slot in motherSlots) {
        if (action.cancelToken.isCancelled) break;
        await state.ensureViewerId(slot.child);
        final fresh = state.accountById(slot.child.id)!;
        final viewerId = fresh.viewerId;
        if (viewerId == null) {
          track('«${slot.child.label}»: нет viewerId — пропуск invite');
          continue;
        }
        final chatIds = slot.groups.map((g) => g.chatId).toList();
        final groupsPayload = [
          for (final g in slot.groups)
            {
              'chatId': g.chatId,
              'title': g.title,
              if (g.inviteHash != null) 'hash': g.inviteHash,
            },
        ];
        track('Приглашение «${slot.child.label}» → ${chatIds.length} групп');
        final inviteResult = await MaxMotherService.inviteChildren(
          motherToken: mother.apiToken!,
          links: const [],
          groups: groupsPayload,
          chatIds: chatIds,
          inviteUserIds: [viewerId],
          delayMs: state.rateSettings.motherJoinDelayMs,
          proxy: (motherProxy != null && motherProxy.isNotEmpty) ? motherProxy : null,
          onProgress: track,
          cancel: action.cancelToken,
        );
        await state.recordMembershipsFromJoinResults(
          motherAccountId: mother.id,
          children: [fresh],
          results: inviteResult.results,
          titleByChatId: {for (final g in slot.groups) g.chatId: g.title},
        );
        await state.addPipelineJournal(
          kind: PipelineJournalKind.joinById,
          message: '«${slot.child.label}»: приглашений ${inviteResult.invited}',
          motherAccountId: mother.id,
          childAccountId: slot.child.id,
        );

        final template = state.joinTemplateForAccount(slot.child.id);
        if (template != null && template.isActive && inviteResult.invited > 0) {
          final chatIdsForWrite = slot.groups.map((g) => g.chatId).toList();
          final channelLinks = await state.ensureChannelInviteLinks(
            [fresh],
            onLog: (msg, {String level = 'info'}) => track(msg),
            cancel: action.cancelToken,
          );
          await ChildPostJoinRunner.runPerAccountChats(
            children: [fresh],
            chatIdsByAccountId: {fresh.id: chatIdsForWrite},
            templateFor: (_) => template,
            channelLinkFor: (child) =>
                channelLinks[child.id] ??
                state.channelPolicyFor(child.id).lastCreatedInviteUrl,
            onLog: (msg, {String level = 'info'}) => track(msg),
            rateSettings: state.rateSettings,
            cancel: action.cancelToken,
          );
        }
      }

      mothersDone++;
      state.updateActionProgress(
        action.id,
        done: mothersDone,
        total: byMother.length,
      );
    }

    if (action.cancelToken.isCancelled) {
      state.finishAction(action.id, status: ActiveActionStatus.cancelled);
    } else {
      state.finishAction(action.id, message: 'Готово (по ID)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final plan = _plan(state);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Запуск',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Дочки делят назначенные группы и входят по invite-ссылкам. Матка не вступает.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    plan.summaryLine,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (plan.totalWithoutLink > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Без ссылки: ${plan.totalWithoutLink} — в link-режиме будут пропущены',
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ],
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _inviteById,
                    onChanged: _running
                        ? null
                        : (v) => setState(() => _inviteById = v ?? false),
                    title: const Text('Добавлять по ID (матка вступит)', style: TextStyle(fontSize: 13)),
                    subtitle: const Text(
                      'Выкл. по умолчанию. Вкл. — матка входит и inviteUsers.',
                      style: TextStyle(fontSize: 11),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: plan.isEmpty
              ? Center(
                  child: Text(
                    plan.error ?? 'Сначала назначьте группы на шаге «Раздача»',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final summary in plan.motherSummaries) ...[
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.hive_outlined, size: 20),
                        title: Text('Матка «${summary.mother.label}» · ${summary.clusterName}'),
                        subtitle: Text(
                          '${summary.groupCount} групп → ${summary.children.length} дочек'
                          '${summary.withoutLinkCount > 0 ? ' · без ссылки: ${summary.withoutLinkCount}' : ''}',
                        ),
                      ),
                      for (final slot in plan.slots.where((s) => s.mother.id == summary.mother.id))
                        Padding(
                          padding: const EdgeInsets.only(left: 40, bottom: 4),
                          child: Text(
                            '· ${slot.child.label}: ${slot.groupCount} групп'
                            '${slot.withoutLinkCount > 0 ? ' (−${slot.withoutLinkCount} без ссылки)' : ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      const Divider(height: 16),
                    ],
                    if (_log.isNotEmpty) ...[
                      const Text('Журнал запуска', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      for (final line in _log.take(40))
                        Text(line, style: const TextStyle(fontSize: 11, fontFamily: 'Consolas')),
                    ],
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: FilledButton.icon(
            onPressed: _running || !plan.ok ? null : () => _run(state),
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_running
                ? 'Работает…'
                : (_inviteById ? 'Запустить (по ID)' : 'Запустить по ссылкам')),
          ),
        ),
      ],
    );
  }
}
