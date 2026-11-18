import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mianban/app.dart';
import 'package:mianban/domain/sleep_data.dart';
import 'package:mianban/platform/sleep_platform.dart';
import 'package:mianban/sleep_controller.dart';
import 'package:mianban/ui/recording_settings.dart';
import 'package:mianban/ui/widgets.dart';
import 'package:mianban/ui/trend_chart.dart';

class FakeSleepPlatform implements SleepPlatform {
  SleepSnapshot value = const SleepSnapshot(version: 'test');
  final List<String> commands = [];
  final Map<String, Map<String, dynamic>> details = {};
  final List<String> detailRequests = [];
  final List<String?> playedClips = [];
  final List<String> correctedClips = [];
  RecordingSettings settings = const RecordingSettings();
  @override
  Future<RecordingSettings> recordingSettings() async => settings;
  @override
  Future<void> saveRecordingSettings(RecordingSettings value) async {
    settings = value;
  }

  bool playbackFails = false;
  @override
  Future<SleepSnapshot> snapshot() async => value;
  @override
  Future<void> command(String action) async {
    commands.add(action);
  }

  @override
  Future<SessionDetail> detail(String sessionId) async {
    detailRequests.add(sessionId);
    return SessionDetail.fromJson(
      details[sessionId] ??
          {
            'summary': {'id': sessionId, 'nightId': '2026-11-08'},
            'chunks': [],
            'buckets': [],
          },
    );
  }

  @override
  Future<void> classify(
    String sessionId,
    String chunkId,
    String classification,
  ) async {
    correctedClips.add(chunkId);
  }

  @override
  Future<void> saveNote(String nightId, List<String> tags, String note) async {}
  @override
  Future<Map<String, dynamic>> playback(
    String action, {
    String? sessionId,
    String? chunkId,
    int? positionMs,
  }) async {
    if (playbackFails) {
      throw PlatformException(code: 'playback_failed', message: '暂时无法播放录音');
    }
    if (action == 'play') playedClips.add(chunkId);
    return {};
  }
}

void main() {
  testWidgets(
    'detail compares the latest record, groups clips and collapses full audio',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakeSleepPlatform();
      const qaFont = String.fromEnvironment('QA_FONT');
      const qaIconFont = String.fromEnvironment('QA_ICON_FONT');
      if (qaFont.isNotEmpty) {
        await tester.runAsync(() async {
          final font = FontLoader('Roboto')
            ..addFont(
              File(qaFont)
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes)),
            );
          await font.load();
          if (qaIconFont.isNotEmpty) {
            final icons = FontLoader('MaterialIcons')
              ..addFont(
                File(qaIconFont)
                    .readAsBytes()
                    .then((bytes) => ByteData.sublistView(bytes)),
              );
            await icons.load();
          }
        });
      }
      final currentStart = DateTime(2026, 11, 12, 2, 24).millisecondsSinceEpoch;
      final previousStart = DateTime(2026, 11, 9, 1).millisecondsSinceEpoch;
      Map<String, dynamic> summary(
        String id,
        String night,
        int start,
        int snore,
      ) => {
        'id': id,
        'nightId': night,
        'startAt': start,
        'activeMs': 300000,
        'validMs': 300000,
        'targetMs': 300000,
        'snoreMs': snore,
        'storageMode': 'full',
      };
      final current = summary('current', '2026-11-11', currentStart, 8000);
      final previous = summary('previous', '2026-11-08', previousStart, 4000);
      platform.value = SleepSnapshot.fromJson({
        'sessions': [current, previous],
      });
      final events = [
        {
          'id': 'event-00001',
          'startAt': currentStart,
          'durationMs': 28000,
          'snoreMs': 6000,
          'audioAvailable': true,
        },
        {
          'id': 'event-00002',
          'startAt': currentStart + 150000,
          'durationMs': 10000,
          'snoreMs': 2000,
          'audioAvailable': true,
        },
      ];
      platform.details['current'] = {
        'summary': current,
        'events': events,
        'recording': {
          'id': 'recording',
          'startAt': currentStart,
          'durationMs': 300000,
          'audioAvailable': true,
        },
        'periods': [
          {
            'id': 'period-00001-00002',
            'startAt': currentStart,
            'endAt': currentStart + 160000,
            'durationMs': 38000,
            'snoreMs': 8000,
            'audioAvailable': true,
            'events': events,
          },
        ],
        'buckets': List.generate(
          5,
          (i) => {
            'offsetMs': i * 60000,
            'validMs': 60000,
            'snoreMs': i == 0 ? 8000 : 0,
          },
        ),
      };
      platform.details['previous'] = {
        'summary': previous,
        'events': [],
        'buckets': [
          {'offsetMs': 0, 'validMs': 60000, 'snoreMs': 4000},
        ],
      };
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MianbanApp(platform: platform),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('对比11月8日晚'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      await tester.ensureVisible(find.text('查看明细与录音'));
      await tester.tap(find.text('查看明细与录音'));
      await tester.pumpAndSettle();
      expect(platform.detailRequests, containsAll(['current', 'previous']));
      expect(find.text('本次 · 11月11日晚'), findsOneWidget);
      expect(find.text('上次 · 11月8日晚'), findsOneWidget);
      final lanes = tester
          .widgetList<SoundDistribution>(find.byType(SoundDistribution))
          .toList();
      expect(lanes.length, 2);
      expect(lanes.map((lane) => lane.minuteCount), everyElement(5));
      await tester.ensureVisible(find.text('回听代表时段'));
      await tester.tap(find.text('回听代表时段'));
      await tester.pumpAndSettle();
      expect(platform.playedClips.last, 'period-00001-00002');
      Future<void> capture(String name) async {
        if (!const bool.fromEnvironment('CAPTURE_QA')) return;
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('qa/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.ensureVisible(find.byType(NightDistributionComparison));
      await tester.pumpAndSettle();
      await capture('periods-comparison');
      expect(find.byType(ClipPlayback), findsOneWidget);
      await tester.ensureVisible(find.text('全程录音'));
      await tester.tap(find.text('全程录音'));
      await tester.pumpAndSettle();
      expect(find.byType(ClipPlayback), findsNWidgets(2));
      await tester.tap(find.text('全程录音'));
      await tester.pumpAndSettle();
      expect(find.byType(ClipPlayback), findsOneWidget);
      await tester.ensureVisible(find.text('查看2段明细'));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byType(ClipPlayback).first),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await capture('periods-grouped');
      await tester.tap(find.byTooltip('播放录音').first);
      await tester.pumpAndSettle();
      expect(platform.playedClips.last, 'period-00001-00002');
      await tester.tap(find.text('查看2段明细'));
      await tester.pumpAndSettle();
      expect(find.text('02:24:00–02:24:28'), findsOneWidget);
      await tester.ensureVisible(find.text('其他声音').first);
      await tester.tap(find.text('其他声音').first);
      await tester.pumpAndSettle();
      expect(platform.correctedClips.last, 'event-00001');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('recording settings save both modes and loudness preference', (
    tester,
  ) async {
    final platform = FakeSleepPlatform();
    await tester.pumpWidget(
      MaterialApp(home: RecordingSettingsScreen(platform: platform)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅保留鼾声'));
    await tester.pumpAndSettle();
    expect(platform.settings.storageMode, 'snore');
    await tester.tap(find.text('清晰'));
    await tester.pumpAndSettle();
    expect(platform.settings.audioBitRate, 48000);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(platform.settings.enhanceAudio, isFalse);
    await tester.tap(find.text('全程保存'));
    await tester.pumpAndSettle();
    expect(platform.settings.storageMode, 'full');
    expect(platform.settings.audioBitRate, 48000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed playback remains associated with the requested clip', (
    tester,
  ) async {
    final player = PlaybackController(
      FakeSleepPlatform()..playbackFails = true,
    );
    await player.toggle('session', 'chunk-00001');
    expect(player.matches('session', 'chunk-00001'), isTrue);
    expect(player.error, '暂时无法播放录音');
    expect(player.playing, isFalse);
    player.dispose();
  });

  testWidgets('empty screen starts monitoring through the native abstraction', (
    tester,
  ) async {
    final platform = FakeSleepPlatform();
    await tester.pumpWidget(MianbanApp(platform: platform));
    await tester.pumpAndSettle();
    expect(find.text('今晚开始，了解自己的鼾声。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-monitoring')));
    await tester.pumpAndSettle();
    expect(platform.commands, ['start']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tabs and information controls work at a narrow width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MianbanApp(platform: FakeSleepPlatform()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('状态'));
    await tester.pumpAndSettle();
    expect(find.text('数据积累中'), findsOneWidget);
    await tester.tap(find.byTooltip('评分依据'));
    await tester.pumpAndSettle();
    expect(find.text('知道了'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('existing records render metrics and open detail', (
    tester,
  ) async {
    final platform = FakeSleepPlatform()
      ..value = SleepSnapshot.fromJson({
        'version': 'test',
        'sessions': [
          {
            'id': 'session',
            'nightId': '2026-11-08',
            'validMs': 14400000,
            'targetMs': 14400000,
            'snoreMs': 1440000,
            'strongMs': 0,
          },
        ],
      });
    await tester.pumpWidget(MianbanApp(platform: platform));
    await tester.pumpAndSettle();
    expect(find.text('10%'), findsOneWidget);
    await tester.ensureVisible(find.text('查看明细与录音'));
    await tester.tap(find.text('查看明细与录音'));
    await tester.pumpAndSettle();
    expect(find.text('夜间概览'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
