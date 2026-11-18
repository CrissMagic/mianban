import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/sleep_data.dart';
import '../sleep_controller.dart';

const paper = Color(0xfff6f4ee);
const forest = Color(0xff315a49);
const ink = Color(0xff24342d);
const muted = Color(0xff687164);
const line = Color(0xffe1e4d9);
const cream = Color(0xfffffef9);
const sage = Color(0xffeaf0e5);

void showInformation(BuildContext context, String title, String body) {
  FocusManager.instance.primaryFocus?.unfocus();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: cream,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭说明',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                body,
                style: const TextStyle(fontSize: 15, height: 1.9, color: muted),
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                label: '知道了',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class InfoButton extends StatelessWidget {
  const InfoButton({super.key, required this.title, required this.body});
  final String title, body;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: title,
    visualDensity: VisualDensity.compact,
    onPressed: () => showInformation(context, title, body),
    icon: const Icon(Icons.info_outline_rounded, size: 18, color: muted),
  );
}

class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.color = cream,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final Color color;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Material(
    color: color,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: line),
    ),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: double.infinity,
      child: Padding(padding: padding, child: child),
    ),
  );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.secondary = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool secondary;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 54,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: secondary ? const Color(0xffedf0e7) : forest,
        foregroundColor: secondary ? forest : cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    ),
  );
}

class PageFooter extends StatelessWidget {
  const PageFooter({super.key, required this.snapshot});
  final SleepSnapshot snapshot;
  @override
  Widget build(BuildContext context) {
    final updated = snapshot.sessions.fold<double>(
      0,
      (total, session) => math.max(total, session.updatedAt),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 26, 6, 20),
      child: SizedBox(
        width: double.infinity,
        child: Text(
          '眠伴 ${snapshot.version} · YAMNet / alpha-1\n'
          '评分仅反映实验性鼾声负担，不代表整体睡眠质量或医学诊断。'
          '${updated > 0 ? '\n更新于${timeLabel(updated)}' : ''}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 10, height: 1.7, color: muted),
        ),
      ),
    );
  }
}

class ErrorNotice extends StatelessWidget {
  const ErrorNotice({super.key, required this.message, this.onDismiss});
  final String message;
  final VoidCallback? onDismiss;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 18),
    padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
    decoration: BoxDecoration(
      color: const Color(0xfff2e3d9),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: Color(0xff76432b),
              height: 1.6,
              fontSize: 13,
            ),
          ),
        ),
        if (onDismiss != null)
          IconButton(
            tooltip: '关闭提示',
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
          ),
      ],
    ),
  );
}

class NightOverview extends StatelessWidget {
  const NightOverview({super.key, required this.night, this.previous});
  final SleepNight night;
  final SleepNight? previous;
  @override
  Widget build(BuildContext context) => Surface(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
    color: sage,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _metric(SleepMetric.duration, primary: true),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 10),
        for (final metric in [
          SleepMetric.share,
          SleepMetric.strong,
          SleepMetric.analysis,
        ])
          _metric(metric),
      ],
    ),
  );

  Widget _metric(SleepMetric metric, {bool primary = false}) {
    final change = compareNights(night, previous, metric);
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            metric.label,
            style: const TextStyle(fontSize: 13, color: muted),
          ),
        ),
        InfoButton(title: metric.label, body: metricDefinitions[metric]!),
      ],
    );
    final monitoringMs = night.activeMs ?? night.targetMs;
    final value = Text(
      metric == SleepMetric.analysis && monitoringMs > 0
          ? '${metric.formatted(night)} / ${durationLabel(monitoringMs)}'
          : metric.formatted(night),
      textAlign: TextAlign.end,
      style: TextStyle(
        fontSize: primary ? 40 : 17,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final comparison = previous == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (change.direction != 0)
                Icon(
                  change.direction > 0
                      ? Icons.arrow_upward
                      : Icons.arrow_downward,
                  size: 13,
                  color: change.good ? forest : muted,
                ),
              Flexible(
                child: Text(
                  change.text,
                  style: TextStyle(
                    fontSize: 12,
                    color: change.good ? forest : muted,
                  ),
                ),
              ),
            ],
          );
    if (primary) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [label, value, ?comparison],
      );
    }
    return Row(
      children: [
        Expanded(flex: metric == SleepMetric.analysis ? 5 : 1, child: label),
        const SizedBox(width: 8),
        Expanded(
          flex: metric == SleepMetric.analysis ? 7 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [value, ?comparison],
          ),
        ),
      ],
    );
  }
}

const metricDefinitions = {
  SleepMetric.duration:
      '模型判断为鼾声的声音窗累计时长，当前每窗约0.975秒。与最近一次有有效分析的记录比较，使用相对百分比。短记录的变化只反映所录时段。',
  SleepMetric.share: '鼾声时长除以有效分析时长。与最近一次有有效分析的记录比较，使用百分点。对比会标出实际日期，测试记录不参与。',
  SleepMetric.strong:
      '模型判断为鼾声，且录音电平相对环境基线增加至少12 dB的时长，除以有效分析时长。它是鼾声的一部分，受摆放距离和手机收音处理影响。',
  SleepMetric.analysis: '斜杠前是有效分析时长，后是监测时长。分析排除校准、暂停、系统静音和严重削波窗。',
};

const phaseLabels = {
  'starting': '正在准备',
  'calibrating': '正在校准环境',
  'recording': '监测中',
  'recovering': '正在恢复收音',
  'paused': '已暂停',
  'stopping': '正在保存',
  'completed': '已完成',
  'interrupted': '意外中断',
  'error': '记录已停止',
};

String monitoringClock(double milliseconds) {
  final seconds = (milliseconds / 1000).floor();
  final hours = seconds ~/ 3600;
  return hours == 0
      ? clock(milliseconds)
      : '$hours:${clock((seconds % 3600) * 1000.0)}';
}

class MonitoringCard extends StatelessWidget {
  const MonitoringCard({
    super.key,
    required this.session,
    required this.busy,
    required this.onCommand,
  });
  final SleepSession session;
  final bool busy;
  final Future<void> Function(String) onCommand;
  @override
  Widget build(BuildContext context) {
    const nightSurface = Color(0xff18372e);
    const nightText = Color(0xffc6dfcd);
    const meterColor = Color(0xffabd2ad);
    final stopping = session.status == 'stopping';
    final paused = session.status == 'paused';
    final level = session.inputLevel;
    final calibration = session.status == 'calibrating';
    final inputText = paused
        ? '已暂停收音'
        : session.inputUnavailable
        ? '当前未收到麦克风声音'
        : level == null
        ? '等待收音'
        : level < -55
        ? '当前声音较轻'
        : '已收到声音';

    return Surface(
      color: nightSurface,
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: cream),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.circle, size: 8, color: meterColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    phaseLabels[session.status] ?? session.status,
                    style: const TextStyle(
                      color: nightText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (session.source == 'validation')
                  const Text(
                    '模拟器测试',
                    style: TextStyle(color: nightText, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Text(
              monitoringClock(session.activeMs),
              semanticsLabel: '已监测 ${durationLabel(session.activeMs)}',
              style: const TextStyle(
                fontSize: 42,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '麦克风',
                    style: TextStyle(fontSize: 13, color: nightText),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    inputText,
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 13, color: nightText),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: paused || level == null
                  ? 0.0
                  : ((level + 80) / 65).clamp(0, 1).toDouble(),
              color: meterColor,
              backgroundColor: Colors.white24,
              minHeight: 7,
              borderRadius: BorderRadius.circular(4),
              semanticsLabel: inputText,
            ),
            if (calibration || (!paused && session.inputUnavailable)) ...[
              const SizedBox(height: 14),
              Text(
                session.inputUnavailable
                    ? '检查麦克风权限及系统麦克风开关。'
                    : '轻声说话，观察麦克风电平是否变化。',
                style: const TextStyle(fontSize: 13, color: nightText),
              ),
            ],
            if (calibration) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '环境校准',
                      style: TextStyle(fontSize: 13, color: nightText),
                    ),
                  ),
                  if (session.calibrationProgress case final progress?)
                    Text(
                      '${(progress * 100).round()}%',
                      style: const TextStyle(fontSize: 13, color: nightText),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: session.calibrationProgress,
                color: nightText,
                backgroundColor: Colors.white24,
                minHeight: 3,
                semanticsLabel: '环境校准进度',
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _monitoringMetric(
                    '鼾声',
                    durationLabel(session.snoreMs),
                  ),
                ),
                Expanded(
                  child: _monitoringMetric(
                    '有效分析',
                    durationLabel(session.validMs),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (session.status == 'recording' && !session.inputUnavailable)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '监测中可锁屏。',
                  style: TextStyle(fontSize: 13, color: nightText),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    secondary: true,
                    label: paused ? '继续监测' : '暂停',
                    icon: paused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    onPressed: busy || stopping
                        ? null
                        : () => onCommand(paused ? 'resume' : 'pause'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PrimaryButton(
                    label: '结束并保存',
                    icon: Icons.stop_rounded,
                    onPressed: busy || stopping
                        ? null
                        : () => onCommand('stop'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _monitoringMetric(String label, String value) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: Color(0xffc6dfcd)),
      ),
    ],
  );
}

class BadgeLabel extends StatelessWidget {
  const BadgeLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xffdfe8d8),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(text, style: const TextStyle(fontSize: 11, color: forest)),
  );
}

String nightSummary(SleepNight night) {
  if (night.validMs == 0) return '本次还没有足够的可用声音。';
  if (night.validation) {
    return '含模拟器测试数据，已分析${durationLabel(night.validMs)}，不计入评分。';
  }
  if (night.score == null) {
    return '已分析${durationLabel(night.validMs)}，继续积累完整夜间记录。';
  }
  return '鼾声占有效分析的${decimal(night.share * 100)}%，较强鼾声占${decimal(night.strongShare * 100)}%。';
}

class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.text,
    this.title = '记录摘要',
    this.info = true,
  });
  final String text, title;
  final bool info;
  @override
  Widget build(BuildContext context) => Surface(
    color: sage,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.eco_outlined, size: 20, color: forest),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (info)
              const InfoButton(
                title: '摘要依据',
                body: '本卡片由本地统计规则生成。AI分析在独立模块手动触发，使用模型设置中配置的供应商与型号。',
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(text, style: const TextStyle(fontSize: 15, height: 1.8)),
      ],
    ),
  );
}

class ClipPlayback extends StatefulWidget {
  const ClipPlayback({
    super.key,
    required this.player,
    required this.sessionId,
    required this.chunk,
  });
  final PlaybackController player;
  final String sessionId;
  final SoundChunk chunk;
  @override
  State<ClipPlayback> createState() => _ClipPlaybackState();
}

class _ClipPlaybackState extends State<ClipPlayback> {
  double? _scrubPosition;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.player,
    builder: (context, _) {
      final player = widget.player;
      final selected = player.matches(widget.sessionId, widget.chunk.id);
      final duration = selected && player.durationMs > 0
          ? player.durationMs
          : widget.chunk.durationMs;
      final position = _scrubPosition ?? (selected ? player.positionMs : 0);
      return Column(
        children: [
          Row(
            children: [
              IconButton.filled(
                tooltip: selected && player.playing ? '暂停回听' : '播放录音',
                onPressed: player.busy
                    ? null
                    : () => player.toggle(widget.sessionId, widget.chunk.id),
                icon: Icon(
                  selected && player.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${clock(position)} / ${clock(duration)}',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
              Expanded(
                child: Slider(
                  value: position.clamp(0, math.max(1, duration)),
                  min: 0,
                  max: math.max(1, duration),
                  onChanged: selected && !player.busy
                      ? (value) => setState(() => _scrubPosition = value)
                      : null,
                  onChangeEnd: selected && !player.busy
                      ? (value) async {
                          await player.seek(value);
                          if (mounted) setState(() => _scrubPosition = null);
                        }
                      : null,
                ),
              ),
            ],
          ),
          if (selected && player.error.isNotEmpty)
            Text(
              player.error,
              style: const TextStyle(color: Color(0xff76432b), fontSize: 12),
            ),
        ],
      );
    },
  );
}
