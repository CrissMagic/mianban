import 'package:flutter_test/flutter_test.dart';
import 'package:mianban/domain/sleep_data.dart';

SleepSession session(
  String id, {
  String night = '2026-11-08',
  double valid = 14400000,
  double target = 15000000,
  double snore = 1440000,
  double strong = 720000,
  double uncertain = 0,
  String source = 'microphone',
}) => SleepSession.fromJson({
  'id': id,
  'nightId': night,
  'startAt': 1,
  'validMs': valid,
  'targetMs': target,
  'snoreMs': snore,
  'strongMs': strong,
  'uncertainMs': uncertain,
  'source': source,
});

void main() {
  test('dates use the previous calendar day before noon', () {
    expect(currentNight(DateTime(2026, 11, 9, 6)), '2026-11-08');
    expect(currentNight(DateTime(2026, 11, 9, 15)), '2026-11-09');
    expect(addDays('2026-03-01', -1), '2026-02-28');
  });
  test('multiple sessions aggregate raw durations', () {
    final nights = groupNights(
      SleepSnapshot(
        sessions: [
          session('a'),
          session(
            'b',
            valid: 3600000,
            target: 4000000,
            snore: 720000,
            strong: 0,
          ),
        ],
      ),
    );
    expect(nights.single.validMs, 18000000);
    expect(nights.single.share, .12);
    expect(nights.single.coverage, 18000000 / 19000000);
  });
  test('uncertainty and short recordings withhold scores', () {
    expect(
      groupNights(SleepSnapshot(sessions: [session('a', uncertain: 1800000)]))
          .single
          .score,
      isNull,
    );
    expect(
      groupNights(SleepSnapshot(sessions: [session('a', valid: 60000)]))
          .single
          .score,
      isNull,
    );
  });
  test('validation audio never contributes to scores', () {
    expect(
      groupNights(SleepSnapshot(sessions: [session('a', source: 'validation')]))
          .single
          .score,
      isNull,
    );
  });
  test('legacy sessions and notes parse without model metadata', () {
    final snapshot = SleepSnapshot.fromJson({
      'sessions': [
        {'id': 'a', 'nightId': '2026-11-08', 'validMs': 1000},
      ],
      'notes': {
        '2026-11-08': {
          'tags': ['侧卧'],
          'note': '备注',
        },
      },
    });
    expect(groupNights(snapshot).single.note.note, '备注');
    expect(snapshot.sessions.single.model, 'YAMNet 1 / alpha-1');
  });
  test(
    'comparison uses the most recent earlier record across missing nights',
    () {
      final nights = groupNights(
        SleepSnapshot(
          sessions: [
            session('a'),
            session('b', night: '2026-11-06'),
          ],
        ),
      );
      expect(
        compareNights(nights.first, nights.last, SleepMetric.share).text,
        '持平',
      );
      expect(
        previousRecordedNight(nights.reversed.toList(), nights.first.id)?.id,
        '2026-11-06',
      );
    },
  );
  test('short recordings compare raw metrics without requiring a score', () {
    final nights = groupNights(
      SleepSnapshot(
        sessions: [
          session('a', valid: 60000, target: 60000, snore: 6000, strong: 0),
          session(
            'b',
            night: '2026-11-03',
            valid: 60000,
            target: 60000,
            snore: 3000,
            strong: 0,
          ),
        ],
      ),
    );
    expect(nights.first.score, isNull);
    expect(
      compareNights(nights.first, nights.last, SleepMetric.share).text,
      '5个百分点',
    );
    expect(previousRecordedNight(nights, nights.last.id), isNull);
    expect(
      compareNights(nights.last, nights.first, SleepMetric.share).text,
      '暂无对比',
    );
  });
  test('comparison skips empty and validation records', () {
    final nights = groupNights(
      SleepSnapshot(
        sessions: [
          session('empty', night: '2026-11-07', valid: 0),
          session('test', night: '2026-11-06', source: 'validation'),
          session('prior', night: '2026-11-02'),
        ],
      ),
    );
    expect(previousRecordedNight(nights, '2026-11-08')?.id, '2026-11-02');
  });
  test('distribution combines sessions while preserving pauses on the elapsed axis', () {
    SessionDetail detail(String id, int start, int valid, int snore) =>
        SessionDetail.fromJson({
          'summary': {
            'id': id,
            'nightId': '2026-11-08',
            'startAt': start,
            'activeMs': 60000,
          },
          'events': [],
          'buckets': [
            {'offsetMs': 0, 'validMs': valid, 'snoreMs': snore},
          ],
        });
    final buckets = nightDistribution([
      detail('later', 180000, 30000, 15000),
      detail('first', 0, 60000, 6000),
    ]);
    expect(buckets.length, 4);
    expect(buckets[0].snoreMs, 6000);
    expect(buckets[1].validMs, 0);
    expect(buckets[2].validMs, 0);
    expect(buckets[3].snoreMs, 15000);
  });
  test('ratio comparison uses percentage points and duration uses relative percent', () {
    final nights = groupNights(
      SleepSnapshot(
        sessions: [
          session('a', snore: 2880000),
          session('b', night: '2026-11-07'),
        ],
      ),
    );
    expect(
      compareNights(nights.first, nights.last, SleepMetric.share).text,
      '10个百分点',
    );
    expect(
      compareNights(nights.first, nights.last, SleepMetric.duration).text,
      '100%',
    );
  });
  test('recent score pools durations from three eligible nights', () {
    final nights = groupNights(
      SleepSnapshot(
        sessions: [
          session('a'),
          session('b', night: '2026-11-07'),
          session('c', night: '2026-11-06', snore: 2880000),
        ],
      ),
    );
    final recent = RecentStatus(nights, '2026-11-08');
    expect(recent.eligible.length, 3);
    expect(recent.score, scoreFor(96 / 720, 36 / 720));
  });
}
