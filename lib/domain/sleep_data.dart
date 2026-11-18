import 'dart:math' as math;

double _number(Map<String, dynamic> json, String key) =>
    (json[key] as num?)?.toDouble() ?? 0;

String dateId(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String addDays(String id, int days) {
  final date = DateTime.parse('${id}T12:00:00');
  return dateId(DateTime(date.year, date.month, date.day + days));
}

String currentNight([DateTime? now]) {
  final date = now ?? DateTime.now();
  return dateId(
    DateTime(date.year, date.month, date.day - (date.hour < 12 ? 1 : 0)),
  );
}

List<String> dateRange(String end, int count) =>
    List.generate(count, (index) => addDays(end, index - count + 1));

String nightLabel(String id) {
  final date = DateTime.parse(id);
  return '${date.month}月${date.day}日晚';
}

String shortDate(String id) {
  final date = DateTime.parse(id);
  return '${date.month}/${date.day}';
}

String decimal(double value) =>
    value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');

String durationLabel(double milliseconds) {
  final seconds = (milliseconds / 1000).round();
  final hours = seconds ~/ 3600;
  final minutes = seconds % 3600 ~/ 60;
  final rest = seconds % 60;
  if (hours > 0) return '$hours小时${minutes > 0 ? '$minutes分' : ''}';
  return '$minutes分${rest > 0 ? '$rest秒' : '钟'}';
}

String clock(double milliseconds) {
  final seconds = (milliseconds / 1000).floor();
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
      '${(seconds % 60).toString().padLeft(2, '0')}';
}

String timeLabel(double milliseconds, {bool seconds = false}) {
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds.round());
  return '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}'
      '${seconds ? ':${date.second.toString().padLeft(2, '0')}' : ''}';
}

class SleepSession {
  SleepSession.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      nightId = json['nightId'] as String,
      startAt = _number(json, 'startAt'),
      updatedAt = _number(json, 'updatedAt'),
      activeMs = _number(json, 'activeMs'),
      targetMs = _number(json, 'targetMs'),
      validMs = _number(json, 'validMs'),
      snoreMs = _number(json, 'snoreMs'),
      strongMs = _number(json, 'strongMs'),
      uncertainMs = _number(json, 'uncertainMs'),
      status = json['status'] as String? ?? 'interrupted',
      source = json['source'] as String? ?? 'microphone',
      inputLevel = (json['inputLevel'] as num?)?.toDouble(),
      inputUnavailable = json['inputUnavailable'] == true,
      calibratedFrames = _number(json, 'calibratedFrames'),
      calibrationFrames = _number(json, 'calibrationFrames'),
      stopReason = json['stopReason'] as String? ?? '',
      model = json['model'] as String? ?? 'YAMNet 1 / alpha-1';

  final String id;
  final String nightId;
  final double startAt, updatedAt, activeMs, targetMs, validMs;
  final double snoreMs, strongMs, uncertainMs;
  final String status, source, stopReason, model;
  final double? inputLevel;
  final bool inputUnavailable;
  final double calibratedFrames, calibrationFrames;

  double? get calibrationProgress => calibrationFrames > 0
      ? (calibratedFrames / calibrationFrames).clamp(0, 1).toDouble()
      : null;
}

class NightNote {
  const NightNote({this.tags = const [], this.note = ''});

  factory NightNote.fromJson(Map<String, dynamic> json) => NightNote(
    tags: List<String>.from(json['tags'] as List? ?? []),
    note: json['note'] as String? ?? '',
  );

  final List<String> tags;
  final String note;
}

class SleepSnapshot {
  const SleepSnapshot({
    this.sessions = const [],
    this.active,
    this.notes = const {},
    this.error = '',
    this.version = '',
  });

  factory SleepSnapshot.fromJson(Map<String, dynamic> json) => SleepSnapshot(
    sessions: (json['sessions'] as List? ?? [])
        .map(
          (value) =>
              SleepSession.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList(),
    active: json['active'] is Map
        ? SleepSession.fromJson(
            Map<String, dynamic>.from(json['active'] as Map),
          )
        : null,
    notes: (json['notes'] as Map? ?? {}).map(
      (key, value) => MapEntry(
        key as String,
        NightNote.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    ),
    error: json['error'] as String? ?? '',
    version: json['version'] as String? ?? '',
  );

  final List<SleepSession> sessions;
  final SleepSession? active;
  final Map<String, NightNote> notes;
  final String error, version;
}

class SleepNight {
  const SleepNight({
    required this.id,
    required this.validMs,
    required this.snoreMs,
    required this.strongMs,
    required this.uncertainMs,
    required this.targetMs,
    this.activeMs,
    this.validation = false,
    this.note = const NightNote(),
  });

  final String id;
  final double validMs, snoreMs, strongMs, uncertainMs, targetMs;
  final double? activeMs;
  final bool validation;
  final NightNote note;

  double get coverage => targetMs > 0 ? math.min(1, validMs / targetMs) : 0;
  double get share => validMs > 0 ? snoreMs / validMs : 0;
  double get strongShare => validMs > 0 ? strongMs / validMs : 0;
  int get estimate => scoreFor(share, strongShare);
  int? get score {
    if (validation || validMs < 14400000 || coverage < .8) return null;
    final lower = scoreFor(
      share + uncertainMs / validMs,
      strongShare + uncertainMs / validMs,
    );
    return estimate - lower <= 5 ? estimate : null;
  }
}

int scoreFor(double share, double strongShare) =>
    (100 * math.exp(-2 * (share + strongShare))).round();

List<SleepNight> groupNights(SleepSnapshot snapshot) {
  final groups = <String, List<SleepSession>>{};
  for (final session in snapshot.sessions) {
    groups.putIfAbsent(session.nightId, () => []).add(session);
  }
  final nights = groups.entries.map((entry) {
    double sum(double Function(SleepSession) value) =>
        entry.value.fold(0, (total, session) => total + value(session));
    return SleepNight(
      id: entry.key,
      validMs: sum((session) => session.validMs),
      snoreMs: sum((session) => session.snoreMs),
      strongMs: sum((session) => session.strongMs),
      uncertainMs: sum((session) => session.uncertainMs),
      targetMs: sum((session) => session.targetMs),
      activeMs: sum((session) => math.max(session.activeMs, session.targetMs)),
      validation: entry.value.any((session) => session.source == 'validation'),
      note: snapshot.notes[entry.key] ?? const NightNote(),
    );
  }).toList();
  nights.sort((left, right) => right.id.compareTo(left.id));
  return nights;
}

enum SleepMetric { duration, share, strong, analysis }

SleepNight? previousRecordedNight(List<SleepNight> nights, String currentId) {
  final earlier =
      nights
          .where(
            (night) =>
                night.id.compareTo(currentId) < 0 &&
                night.validMs > 0 &&
                !night.validation,
          )
          .toList()
        ..sort((left, right) => right.id.compareTo(left.id));
  return earlier.firstOrNull;
}

String comparisonLabel(SleepNight? previous) =>
    previous == null ? '暂无对比记录' : '对比${nightLabel(previous.id)}';

extension SleepMetricLabel on SleepMetric {
  String get label => switch (this) {
    SleepMetric.duration => '鼾声时长',
    SleepMetric.share => '鼾声占比',
    SleepMetric.strong => '较强鼾声占比',
    SleepMetric.analysis => '有效分析',
  };

  double value(SleepNight night) => switch (this) {
    SleepMetric.duration => night.snoreMs,
    SleepMetric.share => night.share * 100,
    SleepMetric.strong => night.strongShare * 100,
    SleepMetric.analysis => night.validMs,
  };

  String formatted(SleepNight night) {
    if (night.validMs == 0 && this != SleepMetric.analysis) return '—';
    return switch (this) {
      SleepMetric.duration => durationLabel(night.snoreMs),
      SleepMetric.analysis => durationLabel(night.validMs),
      _ => '${decimal(value(night))}%',
    };
  }
}

class NightComparison {
  const NightComparison(this.text, {this.direction = 0, this.good = false});
  final String text;
  final int direction;
  final bool good;
}

NightComparison compareNights(
  SleepNight current,
  SleepNight? previous,
  SleepMetric metric,
) {
  if (previous == null ||
      previous.id.compareTo(current.id) >= 0 ||
      current.validMs <= 0 ||
      previous.validMs <= 0 ||
      current.validation ||
      previous.validation) {
    return const NightComparison('暂无对比');
  }
  final difference = metric.value(current) - metric.value(previous);
  if (difference.abs() < .00001) return const NightComparison('持平');
  final prior = metric.value(previous);
  final String text;
  if (metric == SleepMetric.share || metric == SleepMetric.strong) {
    text = '${decimal(difference.abs())}个百分点';
  } else if (prior == 0) {
    text = durationLabel(difference.abs());
  } else {
    text = '${decimal((difference / prior * 100).abs())}%';
  }
  return NightComparison(
    text,
    direction: difference.sign.toInt(),
    good: metric != SleepMetric.analysis && difference < 0,
  );
}

class RecentStatus {
  RecentStatus(List<SleepNight> nights, String end)
    : eligible = nights
          .where(
            (night) =>
                night.id.compareTo(addDays(end, -6)) >= 0 &&
                night.id.compareTo(end) <= 0 &&
                night.score != null,
          )
          .toList();

  final List<SleepNight> eligible;
  double get validMs =>
      eligible.fold(0, (total, night) => total + night.validMs);
  double get snoreMs =>
      eligible.fold(0, (total, night) => total + night.snoreMs);
  double get strongMs =>
      eligible.fold(0, (total, night) => total + night.strongMs);
  double get share => validMs > 0 ? snoreMs / validMs : 0;
  double get strongShare => validMs > 0 ? strongMs / validMs : 0;
  int? get score => eligible.length >= 3 ? scoreFor(share, strongShare) : null;
}

class SoundChunk {
  SoundChunk.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      startAt = _number(json, 'startAt'),
      durationMs = _number(json, 'durationMs'),
      snoreMs = _number(json, 'snoreMs'),
      classification = json['classification'] as String? ?? 'model',
      audioAvailable = json['audioAvailable'] as bool? ?? false,
      audioComplete = json['audioComplete'] as bool? ?? true;
  final String id;
  final double startAt, durationMs, snoreMs;
  final String classification;
  final bool audioAvailable;
  final bool audioComplete;
}

class SoundPeriod {
  SoundPeriod.single(SoundChunk event)
    : audio = event,
      endAt = event.startAt + event.durationMs,
      events = [event];
  SoundPeriod.fromJson(Map<String, dynamic> json)
    : audio = SoundChunk.fromJson(json),
      endAt = _number(json, 'endAt'),
      events = (json['events'] as List)
          .map(
            (value) =>
                SoundChunk.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
  final SoundChunk audio;
  final double endAt;
  final List<SoundChunk> events;
}

class MinuteBucket {
  MinuteBucket.fromJson(Map<String, dynamic> json)
    : offsetMs = _number(json, 'offsetMs'),
      validMs = _number(json, 'validMs'),
      snoreMs = _number(json, 'snoreMs');
  final double offsetMs, validMs, snoreMs;
}

class SessionDetail {
  SessionDetail.fromJson(Map<String, dynamic> json)
    : summary = SleepSession.fromJson(
        Map<String, dynamic>.from(json['summary'] as Map),
      ),
      chunks = ((json['events'] ?? json['chunks']) as List)
          .map(
            (value) =>
                SoundChunk.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
      buckets = (json['buckets'] as List)
          .map(
            (value) =>
                MinuteBucket.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
      recording = json['recording'] is Map
          ? SoundChunk.fromJson(
              Map<String, dynamic>.from(json['recording'] as Map),
            )
          : null,
      storageMode =
          (json['summary'] as Map)['storageMode'] as String? ?? 'full',
      periods = (json['periods'] as List? ?? [])
          .map(
            (value) =>
                SoundPeriod.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
  final SleepSession summary;
  final List<SoundChunk> chunks;
  final List<MinuteBucket> buckets;
  final SoundChunk? recording;
  final String storageMode;
  final List<SoundPeriod> periods;
  List<SoundPeriod> get soundPeriods =>
      periods.isEmpty ? chunks.map(SoundPeriod.single).toList() : periods;
}

List<MinuteBucket> nightDistribution(List<SessionDetail> details) {
  if (details.isEmpty) return [];
  final start = details
      .map((detail) => detail.summary.startAt)
      .reduce(math.min);
  final values = <int, (double, double)>{};
  int count = 0;
  for (final detail in details) {
    final offset = detail.summary.startAt - start;
    count = math.max(
      count,
      ((offset +
                  math.max(
                    detail.summary.activeMs,
                    detail.summary.updatedAt - detail.summary.startAt,
                  )) /
              60000)
          .ceil(),
    );
    for (final bucket in detail.buckets) {
      final index = ((offset + bucket.offsetMs) / 60000).floor();
      final prior = values[index] ?? (0.0, 0.0);
      values[index] = (prior.$1 + bucket.validMs, prior.$2 + bucket.snoreMs);
      count = math.max(count, index + 1);
    }
  }
  return List.generate(
    count,
    (index) => MinuteBucket.fromJson({
      'offsetMs': index * 60000,
      'validMs': values[index]?.$1 ?? 0,
      'snoreMs': values[index]?.$2 ?? 0,
    }),
  );
}

class RecordingSettings {
  const RecordingSettings({
    this.storageMode = 'full',
    this.enhanceAudio = true,
    this.audioBitRate = 24000,
  });
  factory RecordingSettings.fromJson(Map<String, dynamic> json) =>
      RecordingSettings(
        storageMode: json['storageMode'] as String? ?? 'full',
        enhanceAudio: json['enhanceAudio'] as bool? ?? true,
        audioBitRate: json['audioBitRate'] == 48000 ? 48000 : 24000,
      );
  final String storageMode;
  final bool enhanceAudio;
  final int audioBitRate;

  RecordingSettings copyWith({
    String? storageMode,
    bool? enhanceAudio,
    int? audioBitRate,
  }) => RecordingSettings(
    storageMode: storageMode ?? this.storageMode,
    enhanceAudio: enhanceAudio ?? this.enhanceAudio,
    audioBitRate: audioBitRate ?? this.audioBitRate,
  );
  Map<String, dynamic> toJson() => {
    'storageMode': storageMode,
    'enhanceAudio': enhanceAudio,
    'audioBitRate': audioBitRate,
  };
}
