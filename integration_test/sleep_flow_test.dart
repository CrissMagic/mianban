import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mianban/main.dart' as app;
import 'package:mianban/domain/sleep_data.dart';
import 'package:mianban/platform/sleep_platform.dart';
import 'package:mianban/ui/widgets.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Flutter UI records, replays the full night and persists notes', (
    tester,
  ) async {
    final platform = NativeSleepPlatform();
    final settings = await platform.recordingSettings();
    addTearDown(() => platform.saveRecordingSettings(settings));
    final before = await platform.snapshot();
    expect(before.active, isNull);
    addTearDown(() => platform.command('stop'));
    final oldIds = before.sessions.map((session) => session.id).toSet();
    app.main();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('录音设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅保留鼾声'));
    await tester.pumpAndSettle();
    expect((await platform.recordingSettings()).storageMode, 'snore');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      (await platform.recordingSettings()).enhanceAudio,
      !settings.enhanceAudio,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('录音设置'));
    await tester.pumpAndSettle();
    expect(find.text('仅保留鼾声'), findsOneWidget);
    await tester.tap(find.text('全程保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    Future<SleepSnapshot> waitFor(
      bool Function(SleepSnapshot) condition,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
        final snapshot = await platform.snapshot();
        if (condition(snapshot)) return snapshot;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      fail('Timed out waiting for the native recording state');
    }

    Future<void> waitForText(String label) async {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (find.text(label).evaluate().isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Missing UI control $label');
        }
        await tester.pump(const Duration(milliseconds: 200));
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    await tester.ensureVisible(
      find.byKey(const ValueKey('start-monitoring')).first,
    );
    await tester.tap(find.byKey(const ValueKey('start-monitoring')).first);
    var snapshot = await waitFor((value) => value.active != null);
    final id = snapshot.active!.id;
    expect(oldIds, isNot(contains(id)));
    await Future<void>.delayed(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('暂停').first);
    await tester.tap(find.text('暂停').first);
    await waitFor((value) => value.active?.status == 'paused');
    await waitForText('继续监测');
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续监测').first);
    await waitFor((value) => value.active?.status != 'paused');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('结束并保存').first);
    snapshot = await waitFor((value) => value.active == null);
    expect(snapshot.sessions.map((session) => session.id), containsAll(oldIds));
    final saved = snapshot.sessions.singleWhere((session) => session.id == id);
    expect(saved.status, 'completed');
    final detail = await platform.detail(id);
    expect(detail.recording?.audioAvailable, isTrue);

    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看当晚明细'));
    await tester.tap(find.text('查看当晚明细'));
    await tester.pumpAndSettle();
    expect(find.text('夜间概览'), findsOneWidget);
    await tester.ensureVisible(find.text('全程录音').first);
    final recordingPanel = find
        .ancestor(
          of: find.text('全程录音').first,
          matching: find.byType(ExpansionTile),
        )
        .first;
    expect(
      find.descendant(of: recordingPanel, matching: find.byType(ClipPlayback)),
      findsNothing,
    );
    await tester.tap(find.text('全程录音').first);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: recordingPanel, matching: find.byType(ClipPlayback)),
      findsOneWidget,
    );
    final playback = await platform.playback(
      'play',
      sessionId: id,
      chunkId: detail.recording!.id,
    );
    expect(playback['playing'], isTrue);
    expect(playback['durationMs'] as num, greaterThan(0));
    await platform.playback('pause');
    await platform.playback('seek', positionMs: 500);
    expect((await platform.playback('state'))['playing'], isFalse);
    await platform.playback('stop');

    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Flutter 迁移自动验证');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存记录'));
    await tester.tap(find.text('保存记录'));
    await tester.pumpAndSettle();
    snapshot = await platform.snapshot();
    expect(snapshot.notes[saved.nightId]?.note, 'Flutter 迁移自动验证');
    final original = before.notes[saved.nightId] ?? const NightNote();
    await platform.saveNote(saved.nightId, original.tags, original.note);
    expect(tester.takeException(), isNull);
  });
}
