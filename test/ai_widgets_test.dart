import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mianban/ai/ai_client.dart';
import 'package:mianban/ai/ai_controller.dart';
import 'package:mianban/ui/ai_settings.dart';
import 'package:mianban/ui/ai_usage.dart';
import 'package:mianban/ui/widgets.dart';

import 'ai_test_support.dart';

void main() {
  testWidgets(
    'settings fetch a dropdown model, save rates and keep the key out of the ledger',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = MemoryAiRepository(), secrets = MemoryAiSecrets();
      final transport = FakeAiTransport()
        ..replies.add(
          AiHttpResponse(
            200,
            jsonEncode({
              'data': [
                {'id': 'fixture-model'},
              ],
            }),
          ),
        );
      final controller = AiController(
        repository: repository,
        secrets: secrets,
        client: AiClient(transport: transport),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: paper),
          home: AiSettingsScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-api-key')),
        'unit-test-key',
      );
      await tester.ensureVisible(find.text('获取模型列表'));
      await tester.tap(find.text('获取模型列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('fixture-model').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('设置模型单价'));
      await tester.tap(find.text('设置模型单价'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('price-0')), '1');
      await tester.enterText(find.byKey(const ValueKey('price-1')), '2');
      await tester.enterText(find.byKey(const ValueKey('price-2')), '0.1');
      await tester.ensureVisible(find.text('应用单价'));
      await tester.tap(find.text('应用单价'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存并使用'));
      await tester.tap(find.text('保存并使用'));
      await tester.pumpAndSettle();
      expect(controller.active.model, 'fixture-model');
      expect(controller.active.price!.input, 1000000);
      expect(secrets.values.values, contains('unit-test-key'));
      expect(
        repository.savedProfiles.values.single.toJson().toString(),
        isNot(contains('unit-test-key')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('cost records expose the saved rate snapshot and raw usage', (
    tester,
  ) async {
    final transport = FakeAiTransport()..replies.add(fakeResponse());
    final controller = AiController(
      repository: MemoryAiRepository(),
      secrets: MemoryAiSecrets(),
      client: AiClient(transport: transport),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.save(
      controller.active.copyWith(
        model: 'fixture-model',
        prices: {'fixture-model': testPrice()},
      ),
      newKey: 'unit-test-key',
    );
    final call = await controller.generate('night:2026-11-08', {'nights': []});
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: AiUsageScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('\$0.00102'), findsOneWidget);
    await tester.tap(find.text('OpenAI · fixture-model'));
    await tester.pumpAndSettle();
    expect(find.text(call.costLabel), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('调用时单价'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('调用时单价'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
