import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/sleep_data.dart';
import 'widgets.dart';

class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.days,
    required this.nights,
    required this.onNight,
  });
  final List<String> days;
  final List<SleepNight> nights;
  final ValueChanged<SleepNight> onNight;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final values = {for (final night in nights) night.id: night};
      return Semantics(
        label: '鼾声占比趋势，可通过每日记录查看明细',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (event) {
            final plotWidth = constraints.maxWidth - 54;
            final fraction = ((event.localPosition.dx - 40) / plotWidth).clamp(
              0,
              1,
            );
            final index = (fraction * (days.length - 1)).round();
            final night = values[days[index]];
            if (night != null && night.validMs > 0) onNight(night);
          },
          child: SizedBox(
            height: 210,
            width: double.infinity,
            child: CustomPaint(painter: _TrendPainter(days, values)),
          ),
        ),
      );
    },
  );
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.days, this.nights);
  final List<String> days;
  final Map<String, SleepNight> nights;

  void _text(
    Canvas canvas,
    String text,
    Offset offset, {
    bool centered = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 10, color: muted),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset - Offset(centered ? painter.width / 2 : 0, 0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromLTRB(40, 14, size.width - 14, size.height - 28);
    final maximum = nights.values.fold<double>(
      0,
      (value, night) => math.max(value, night.share * 100),
    );
    final ceiling = math.max(5, (maximum / 5).ceil() * 5).toDouble();
    final gridPaint = Paint()
      ..color = line.withValues(alpha: .55)
      ..strokeWidth = .6;
    for (var tick = 0; tick <= 4; tick++) {
      final y = area.bottom - area.height * tick / 4;
      _text(canvas, '${decimal(ceiling * tick / 4)}%', Offset(0, y - 6));
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), gridPaint);
    }
    Offset? previous;
    final stroke = Paint()
      ..color = forest
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var index = 0; index < days.length; index++) {
      final x = area.left + area.width * index / math.max(1, days.length - 1);
      if (index == 0 ||
          index == days.length - 1 ||
          index % math.max(1, days.length ~/ 4) == 0) {
        _text(
          canvas,
          shortDate(days[index]),
          Offset(x, area.bottom + 10),
          centered: true,
        );
      }
      final night = nights[days[index]];
      if (night == null || night.validMs == 0) {
        previous = null;
        continue;
      }
      final point = Offset(
        x,
        area.bottom - area.height * night.share * 100 / ceiling,
      );
      if (previous != null) {
        final fill = Path()
          ..moveTo(previous.dx, area.bottom)
          ..lineTo(previous.dx, previous.dy)
          ..lineTo(point.dx, point.dy)
          ..lineTo(point.dx, area.bottom)
          ..close();
        canvas.drawPath(
          fill,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x507e9b85), Color(0x007e9b85)],
            ).createShader(area),
        );
        canvas.drawLine(previous, point, stroke);
      }
      canvas.drawCircle(point, 4, Paint()..color = forest);
      previous = point;
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) => true;
}

class SoundDistribution extends StatelessWidget {
  const SoundDistribution({
    super.key,
    required this.buckets,
    this.minuteCount,
    this.color = forest,
  });
  final List<MinuteBucket> buckets;
  final int? minuteCount;
  final Color color;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '每分钟鼾声占比',
    child: SizedBox(
      height: 82,
      width: double.infinity,
      child: CustomPaint(
        painter: _DistributionPainter(
          buckets,
          minuteCount ?? buckets.length,
          color,
        ),
      ),
    ),
  );
}

class _DistributionPainter extends CustomPainter {
  _DistributionPainter(this.buckets, this.minuteCount, this.color);
  final List<MinuteBucket> buckets;
  final int minuteCount;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (minuteCount == 0) return;
    final width = size.width / minuteCount;
    for (var index = 0; index < buckets.length; index++) {
      final bucket = buckets[index];
      if (bucket.validMs <= 0) continue;
      final fraction = bucket.validMs > 0 ? bucket.snoreMs / bucket.validMs : 0;
      final height = math.max(3, fraction * (size.height - 8)).toDouble();
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            index * width,
            size.height - height,
            math.max(1, width - 2),
            height,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = color.withValues(alpha: .7),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DistributionPainter oldDelegate) => true;
}

class NightDistributionComparison extends StatelessWidget {
  const NightDistributionComparison({
    super.key,
    required this.nightId,
    required this.current,
    required this.previous,
    this.previousId,
    this.error = '',
  });
  final String nightId;
  final String? previousId;
  final List<SessionDetail> current, previous;
  final String error;

  @override
  Widget build(BuildContext context) {
    final currentBuckets = nightDistribution(current);
    final previousBuckets = nightDistribution(previous);
    final count = math.max(currentBuckets.length, previousBuckets.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _lane(
          '本次 · ${nightLabel(nightId)}',
          current,
          currentBuckets,
          count,
          forest,
        ),
        if (previousId != null) ...[
          const SizedBox(height: 18),
          if (error.isNotEmpty)
            Text(error, style: const TextStyle(color: muted, fontSize: 12))
          else
            _lane(
              '上次 · ${nightLabel(previousId!)}',
              previous,
              previousBuckets,
              count,
              const Color(0xff8e8064),
            ),
        ],
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('监测开始', style: TextStyle(color: muted, fontSize: 10)),
            Text(
              durationLabel(count * 30000.0),
              style: const TextStyle(color: muted, fontSize: 10),
            ),
            Text(
              durationLabel(count * 60000.0),
              style: const TextStyle(color: muted, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }

  Widget _lane(
    String label,
    List<SessionDetail> details,
    List<MinuteBucket> buckets,
    int count,
    Color color,
  ) {
    final start = details.isEmpty
        ? null
        : details.map((detail) => detail.summary.startAt).reduce(math.min);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
            if (start != null)
              Text(
                '${timeLabel(start)}开始',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SoundDistribution(buckets: buckets, minuteCount: count, color: color),
      ],
    );
  }
}
