import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/sleep_data.dart';
import '../ai/ai_controller.dart';
import '../sleep_controller.dart';
import 'trend_chart.dart';
import 'widgets.dart';
import 'recording_settings.dart';
import 'ai_analysis.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({
    super.key,
    required this.controller,
    required this.onNight,
  });
  final SleepController controller;
  final ValueChanged<SleepNight> onNight;

  @override
  Widget build(BuildContext context) {
    final nights = controller.nights;
    final latest = nights.firstOrNull;
    final previous = latest == null
        ? null
        : previousRecordedNight(nights, latest.id);
    return SingleChildScrollView(
      key: const PageStorageKey('today'),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (controller.error.isNotEmpty)
            ErrorNotice(
              message: controller.error,
              onDismiss: controller.dismissError,
            ),
          if (controller.active case final session?) ...[
            MonitoringCard(
              session: session,
              busy: controller.busy,
              onCommand: controller.command,
            ),
            const SizedBox(height: 18),
          ],
          if (latest != null) ...[
            TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                foregroundColor: muted,
              ),
              onPressed: () => onNight(latest),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(nightLabel(latest.id)),
                  const SizedBox(width: 8),
                  if (latest.validation) const BadgeLabel('含测试记录'),
                  const Icon(Icons.chevron_right_rounded, size: 20),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              comparisonLabel(previous),
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            NightOverview(night: latest, previous: previous),
            const SizedBox(height: 20),
            Surface(
              padding: EdgeInsets.zero,
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                leading: const Icon(Icons.headphones_rounded, color: forest),
                title: const Text(
                  '查看明细与录音',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => onNight(latest),
              ),
            ),
            const SizedBox(height: 18),
            if (controller.active == null) _startButton(controller),
          ] else if (controller.active == null) ...[
            const SizedBox(height: 42),
            Surface(
              color: sage,
              padding: const EdgeInsets.fromLTRB(24, 38, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.nightlight_outlined, size: 48, color: forest),
                  SizedBox(height: 26),
                  Text(
                    '今晚开始，了解自己的鼾声。',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 18),
                  Text(
                    '把手机放在床头稳固的位置，麦克风朝向枕边。',
                    style: TextStyle(color: muted, height: 1.6),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            _startButton(controller),
          ],
          PageFooter(snapshot: controller.snapshot),
        ],
      ),
    );
  }
}

Widget _startButton(SleepController controller) => PrimaryButton(
  key: const ValueKey('start-monitoring'),
  label: controller.busy ? '正在准备' : '开始监测',
  icon: Icons.mic_none_rounded,
  onPressed: controller.busy ? null : () => controller.command('start'),
);

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({
    super.key,
    required this.controller,
    required this.onNight,
  });
  final SleepController controller;
  final ValueChanged<SleepNight> onNight;
  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  int _range = 7;
  @override
  Widget build(BuildContext context) {
    final nights = widget.controller.nights;
    var end = currentNight();
    if (nights.isNotEmpty && nights.first.id.compareTo(end) > 0) {
      end = nights.first.id;
    }
    final days = dateRange(end, _range);
    final byDate = {for (final night in nights) night.id: night};
    return SingleChildScrollView(
      key: const PageStorageKey('trends'),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '鼾声占比',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 7, label: Text('7天')),
                  ButtonSegment(value: 30, label: Text('30天')),
                ],
                selected: {_range},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
                ),
                onSelectionChanged: (value) =>
                    setState(() => _range = value.first),
              ),
            ],
          ),
          if (nights.isEmpty) ...[
            const SizedBox(height: 60),
            const Center(
              child: Icon(Icons.show_chart_rounded, size: 60, color: forest),
            ),
            const SizedBox(height: 24),
            const Center(
              child: Text('记录后，这里会展示每天的变化。', style: TextStyle(color: muted)),
            ),
            const SizedBox(height: 30),
            _startButton(widget.controller),
          ] else ...[
            const SizedBox(height: 20),
            Surface(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 10),
              child: TrendChart(
                days: days,
                nights: nights,
                onNight: widget.onNight,
              ),
            ),
            const SizedBox(height: 26),
            const Row(
              children: [
                Expanded(
                  child: Text(
                    '每日记录',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                Text('鼾声占比', style: TextStyle(fontSize: 12, color: muted)),
              ],
            ),
            const SizedBox(height: 14),
            Surface(
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Column(
                  children: days.reversed.map((id) {
                    final night = byDate[id];
                    return Column(
                      children: [
                        ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 5,
                          ),
                          enabled: night != null,
                          onTap: night == null
                              ? null
                              : () => widget.onNight(night),
                          title: Text(
                            nightLabel(id),
                            style: TextStyle(
                              fontSize: 14,
                              color: night == null
                                  ? muted.withValues(alpha: .6)
                                  : ink,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                night != null && night.validMs > 0
                                    ? '${decimal(night.share * 100)}%'
                                    : '—',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (night != null)
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                ),
                            ],
                          ),
                        ),
                        if (id != days.first)
                          const Divider(height: 1, color: line),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
          PageFooter(snapshot: widget.controller.snapshot),
        ],
      ),
    );
  }
}

class StatusScreen extends StatelessWidget {
  const StatusScreen({super.key, required this.controller, required this.ai});
  final SleepController controller;
  final AiController ai;
  @override
  Widget build(BuildContext context) {
    var end = currentNight();
    final nights = controller.nights;
    if (nights.isNotEmpty && nights.first.id.compareTo(end) > 0) {
      end = nights.first.id;
    }
    final recent = RecentStatus(nights, end);
    final latest = nights
        .where((night) => night.validMs > 0 && !night.validation)
        .firstOrNull;
    final score = recent.score;
    return SingleChildScrollView(
      key: const PageStorageKey('status'),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Column(
        children: [
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Expanded(
                      child: Text(
                        '近期鼾声评分',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    InfoButton(title: '评分依据', body: scoreDefinition),
                  ],
                ),
                const SizedBox(height: 12),
                if (score != null) ...[
                  Text(
                    '$score 分',
                    style: const TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '最近7晚 · ${recent.eligible.length}晚达标记录',
                    style: const TextStyle(color: muted),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _statusValue(
                          '鼾声占比',
                          '${decimal(recent.share * 100)}%',
                        ),
                      ),
                      Expanded(
                        child: _statusValue(
                          '较强鼾声占比',
                          '${decimal(recent.strongShare * 100)}%',
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  Text(
                    latest == null
                        ? '数据积累中'
                        : '还需${3 - recent.eligible.length}晚达标记录',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: recent.eligible.length / 3,
                    semanticsLabel: '${recent.eligible.length}晚达标，目标3晚',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '最近7晚 · ${recent.eligible.length}/3晚达标',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          AiAnalysisCard(
            controller: ai,
            scope: 'recent7:$end',
            nights: nights
                .where(
                  (night) =>
                      night.id.compareTo(addDays(end, -6)) >= 0 &&
                      night.id.compareTo(end) <= 0,
                )
                .toList(),
          ),
          const SizedBox(height: 18),
          if (controller.active == null) _startButton(controller),
          PageFooter(snapshot: controller.snapshot),
        ],
      ),
    );
  }

  Widget _statusValue(String label, String value) => Column(
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: muted)),
      const SizedBox(height: 8),
      Text(
        value,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500),
      ),
    ],
  );
}

const scoreDefinition =
    '当前实验公式为100 × exp(−2 × (鼾声占比 + 较强鼾声占比))，四舍五入。'
    '每晚有效分析至少4小时、覆盖率至少80%，且无法判断部分造成的评分区间不超过5分。'
    '近期评分汇总最近7晚达标原始时长后计算，至少需要3晚。模拟器注入记录不计入评分。';

class NightDetailScreen extends StatefulWidget {
  const NightDetailScreen({
    super.key,
    required this.night,
    required this.controller,
    required this.player,
    required this.ai,
  });
  final SleepNight night;
  final SleepController controller;
  final PlaybackController player;
  final AiController ai;
  @override
  State<NightDetailScreen> createState() => _NightDetailScreenState();
}

class _NightDetailScreenState extends State<NightDetailScreen> {
  final _representativeKey = GlobalKey();
  List<SessionDetail> _details = [];
  List<SessionDetail> _previousDetails = [];
  String? _comparisonId;
  String _comparisonError = '';
  late final TextEditingController _note;
  late Set<String> _tags;
  bool _loading = true;
  bool _working = false;
  bool _saving = false;
  bool _saved = false;
  int _limit = 12;
  String _error = '';
  String? _activeStatus;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(text: widget.night.note.note);
    _tags = widget.night.note.tags.toSet();
    _activeStatus = widget.controller.active?.status;
    widget.controller.addListener(_onControllerChanged);
    unawaited(_load());
  }

  void _onControllerChanged() {
    final status = widget.controller.active?.status;
    final comparisonId = previousRecordedNight(
      widget.controller.nights,
      widget.night.id,
    )?.id;
    if (_comparisonId != comparisonId) {
      unawaited(_load());
    } else if (_activeStatus != status) {
      _activeStatus = status;
      if (status == null || status == 'paused') unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final comparisonId = previousRecordedNight(
      widget.controller.nights,
      widget.night.id,
    )?.id;
    _comparisonId = comparisonId;
    try {
      final sessions = widget.controller.snapshot.sessions.where(
        (session) => session.nightId == widget.night.id,
      );
      final details = await Future.wait(
        sessions.map(
          (session) => widget.controller.platform.detail(session.id),
        ),
      );
      List<SessionDetail> previousDetails = [];
      String comparisonError = '';
      if (comparisonId != null) {
        try {
          previousDetails = await Future.wait(
            widget.controller.snapshot.sessions
                .where((session) => session.nightId == comparisonId)
                .map(
                  (session) => widget.controller.platform.detail(session.id),
                ),
          );
        } catch (_) {
          comparisonError = '上次声音分布暂时无法读取';
        }
      }
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _details = details;
          _previousDetails = previousDetails;
          _comparisonError = comparisonError;
          _loading = false;
        });
      }
    } catch (failure) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _error = errorMessage(failure);
          _loading = false;
        });
      }
    }
  }

  Future<void> _classify(
    String session,
    String chunk,
    String classification,
  ) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      await widget.controller.platform.classify(session, chunk, classification);
      await widget.controller.refresh();
      await _load();
    } catch (failure) {
      if (mounted) setState(() => _error = errorMessage(failure));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _saveNote() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await widget.controller.saveNote(
        widget.night.id,
        _tags.toList(),
        _note.text,
      );
      if (mounted) setState(() => _saved = true);
    } catch (failure) {
      if (mounted) setState(() => _error = errorMessage(failure));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    unawaited(widget.player.stop());
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final night =
          controller.nights
              .where((item) => item.id == widget.night.id)
              .firstOrNull ??
          widget.night;
      final previous = previousRecordedNight(controller.nights, night.id);
      final periods =
          [
            for (final detail in _details)
              for (final period in detail.soundPeriods)
                (detail.summary.id, period),
          ]..sort(
            (left, right) =>
                left.$2.audio.startAt.compareTo(right.$2.audio.startAt),
          );
      final playable =
          periods
              .where(
                (entry) =>
                    entry.$2.audio.audioAvailable && entry.$2.audio.snoreMs > 0,
              )
              .toList()
            ..sort(
              (left, right) =>
                  right.$2.audio.snoreMs.compareTo(left.$2.audio.snoreMs),
            );
      final representative = playable.firstOrNull;
      final shownPeriods = periods.take(_limit).toList();
      if (representative != null && !shownPeriods.contains(representative)) {
        shownPeriods.add(representative);
      }
      final capturing =
          controller.active != null && controller.active!.status != 'paused';
      final recordings = _details
          .where((detail) => detail.recording?.audioAvailable == true)
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(
            nightLabel(night.id),
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
          ),
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            await controller.refresh();
            await _load();
          },
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error.isNotEmpty)
                  ErrorNotice(
                    message: _error,
                    onDismiss: () => setState(() => _error = ''),
                  ),
                if (controller.error.isNotEmpty)
                  ErrorNotice(
                    message: controller.error,
                    onDismiss: controller.dismissError,
                  ),
                if (controller.active case final session?) ...[
                  MonitoringCard(
                    session: session,
                    busy: controller.busy,
                    onCommand: controller.command,
                  ),
                  const SizedBox(height: 20),
                ],
                Row(
                  children: [
                    const Expanded(
                      child: Text('夜间概览', style: TextStyle(fontSize: 14)),
                    ),
                    Text(
                      comparisonLabel(previous),
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                NightOverview(night: night, previous: previous),
                const SizedBox(height: 20),
                if (representative != null && !capturing) ...[
                  PrimaryButton(
                    label: '回听代表时段',
                    icon: Icons.headphones_rounded,
                    onPressed: () async {
                      final target = _representativeKey.currentContext;
                      if (target != null) {
                        await Scrollable.ensureVisible(
                          target,
                          alignment: .08,
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 240),
                        );
                      }
                      if (mounted) {
                        final period = representative.$2;
                        await widget.player.toggle(
                          representative.$1,
                          period.events.length == 1
                              ? period.events.single.id
                              : period.audio.id,
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                ],
                Surface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Expanded(
                            child: Text(
                              '声音分布',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          InfoButton(
                            title: '声音分布',
                            body: '上下两行分别展示本次与最近一次记录，每根柱代表该分钟的鼾声占比。两行按各自监测开始后的经过时间对齐，使用相同时间尺度。空隙代表暂停或没有可用分析。',
                          ),
                        ],
                      ),
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      if (!_loading) ...[
                        const SizedBox(height: 12),
                        NightDistributionComparison(
                          nightId: night.id,
                          current: _details,
                          previousId: previous?.id,
                          previous: _previousDetails,
                          error: _comparisonError,
                        ),
                      ],
                      for (final detail in _details) ...[
                        if (detail.summary.source == 'validation')
                          const Text(
                            '模拟器测试记录',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        if (detail.summary.stopReason.isNotEmpty)
                          Text(
                            detail.summary.stopReason,
                            style: const TextStyle(color: muted, fontSize: 12),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                for (final detail in recordings)
                  if (detail.recording case final recording?) ...[
                    Surface(
                      padding: EdgeInsets.zero,
                      child: ExpansionTile(
                        key: PageStorageKey('recording-${detail.summary.id}'),
                        title: Text(
                          detail.storageMode == 'full' ? '全程录音' : '已保留音频',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: recordings.length > 1
                            ? Text('${timeLabel(detail.summary.startAt)} 开始')
                            : null,
                        tilePadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 4,
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          20,
                          0,
                          20,
                          16,
                        ),
                        shape: const Border(),
                        collapsedShape: const Border(),
                        onExpansionChanged: (expanded) {
                          if (!expanded &&
                              widget.player.matches(
                                detail.summary.id,
                                recording.id,
                              )) {
                            unawaited(widget.player.stop());
                          }
                        },
                        children: [
                          if (controller.active == null ||
                              controller.active!.status == 'paused')
                            ClipPlayback(
                              player: widget.player,
                              sessionId: detail.summary.id,
                              chunk: recording,
                            )
                          else
                            const Text(
                              '暂停监测后可回听。',
                              style: TextStyle(color: muted, fontSize: 13),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                  ],
                const Row(
                  children: [
                    Expanded(
                      child: Text(
                        '鼾声时段',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    InfoButton(
                      title: '鼾声时段',
                      body: '片段间隔不超过3分钟时归到同一时段，暂停监测会分开。连续回听各段已保存的音频并跳过片段间隔。展开明细可逐段纠正，修改会同步影响时长、趋势和评分。',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!_loading && periods.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(bottom: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '暂无已保存的鼾声时段。',
                          style: TextStyle(color: muted, fontSize: 13),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => RecordingSettingsScreen(
                                platform: controller.platform,
                              ),
                            ),
                          ),
                          child: const Text('查看录音设置'),
                        ),
                      ],
                    ),
                  ),
                for (final (sessionId, period) in shownPeriods) ...[
                  KeyedSubtree(
                    key: (sessionId, period) == representative
                        ? _representativeKey
                        : ValueKey((sessionId, period.audio.id)),
                    child: _periodCard(sessionId, period, capturing),
                  ),
                  const SizedBox(height: 16),
                ],
                if (periods.length > _limit) ...[
                  PrimaryButton(
                    label: '加载更多时段',
                    secondary: true,
                    onPressed: () => setState(() => _limit += 12),
                  ),
                  const SizedBox(height: 18),
                ],
                _notesCard(),
                const SizedBox(height: 18),
                SummaryCard(text: nightSummary(night)),
                const SizedBox(height: 18),
                AiAnalysisCard(
                  controller: widget.ai,
                  scope: 'night:${night.id}',
                  nights: [night, ?previous],
                ),
                PageFooter(snapshot: controller.snapshot),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _periodCard(String sessionId, SoundPeriod period, bool capturing) {
    if (period.events.length == 1) {
      return _chunkCard(sessionId, period.events.single, capturing);
    }
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${timeLabel(period.audio.startAt)}–${timeLabel(period.endAt)}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 10),
          Text(
            '${period.events.length}段 · 鼾声 ${durationLabel(period.audio.snoreMs)}',
            style: const TextStyle(fontSize: 13, color: muted),
          ),
          const SizedBox(height: 12),
          if (capturing)
            const Text(
              '暂停监测后可回听。',
              style: TextStyle(color: muted, fontSize: 13),
            )
          else if (period.audio.audioAvailable)
            ClipPlayback(
              player: widget.player,
              sessionId: sessionId,
              chunk: period.audio,
            )
          else
            const Text(
              '此时段音频未完整保存。',
              style: TextStyle(color: muted, fontSize: 13),
            ),
          ExpansionTile(
            key: PageStorageKey('details-$sessionId-${period.audio.id}'),
            title: Text(
              '查看${period.events.length}段明细',
              style: const TextStyle(fontSize: 13, color: forest),
            ),
            tilePadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            onExpansionChanged: (expanded) {
              if (!expanded &&
                  period.events.any(
                    (event) => widget.player.matches(sessionId, event.id),
                  )) {
                unawaited(widget.player.stop());
              }
            },
            children: [
              for (final event in period.events) ...[
                _chunkCard(sessionId, event, capturing),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _chunkCard(
    String sessionId,
    SoundChunk chunk,
    bool capturing,
  ) => Surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.graphic_eq_rounded, color: forest, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '${timeLabel(chunk.startAt, seconds: true)}–${timeLabel(chunk.startAt + chunk.durationMs, seconds: true)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              durationLabel(chunk.durationMs),
              style: const TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(switch (chunk.classification) {
          'other' => '已标为其他声音',
          'uncertain' => '已标为无法判断',
          _ => '检测到鼾声 ${durationLabel(chunk.snoreMs)}',
        }, style: const TextStyle(color: muted, fontSize: 13)),
        const SizedBox(height: 12),
        if (chunk.audioAvailable && !chunk.audioComplete)
          const Text(
            '部分音频未完整保存。',
            style: TextStyle(color: muted, fontSize: 13),
          ),
        if (capturing)
          const Text('暂停监测后可回听。', style: TextStyle(color: muted, fontSize: 13))
        else if (chunk.audioAvailable)
          ClipPlayback(
            player: widget.player,
            sessionId: sessionId,
            chunk: chunk,
          )
        else
          const Text(
            '此片段音频未完整保存。',
            style: TextStyle(color: muted, fontSize: 13),
          ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'model', label: Text('模型结果')),
              ButtonSegment(value: 'other', label: Text('其他声音')),
              ButtonSegment(value: 'uncertain', label: Text('无法判断')),
            ],
            selected: {chunk.classification},
            showSelectedIcon: false,
            style: const ButtonStyle(
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 2),
              ),
            ),
            onSelectionChanged: _working || capturing
                ? null
                : (value) => _classify(sessionId, chunk.id, value.first),
          ),
        ),
      ],
    ),
  );

  Widget _notesCard() => Surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '睡前记录',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: ['鼻塞', '饮酒', '晚睡', '侧卧', '运动', '疲劳']
              .map(
                (factor) => FilterChip(
                  label: Text(factor, style: const TextStyle(fontSize: 13)),
                  selected: _tags.contains(factor),
                  showCheckmark: false,
                  onSelected: _saving
                      ? null
                      : (selected) => setState(() {
                          selected ? _tags.add(factor) : _tags.remove(factor);
                          _saved = false;
                        }),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          maxLength: 240,
          minLines: 2,
          maxLines: 4,
          onChanged: (_) => setState(() => _saved = false),
          decoration: const InputDecoration(
            hintText: '补充当晚情况',
            counterText: '',
            filled: true,
            fillColor: Color(0xfff9f9f4),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 14),
        PrimaryButton(
          label: _saving
              ? '正在保存'
              : _saved
              ? '已保存'
              : '保存记录',
          icon: _saved ? Icons.check : null,
          secondary: true,
          onPressed: _saving ? null : _saveNote,
        ),
      ],
    ),
  );
}
