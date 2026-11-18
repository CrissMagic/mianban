import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mianban/ai/ai_client.dart';
import 'package:mianban/ai/ai_controller.dart';
import 'package:mianban/ai/ai_models.dart';
import 'package:mianban/ai/ai_repository.dart';
import 'package:mianban/app.dart';
import 'package:mianban/domain/sleep_data.dart';

import '../test/ai_test_support.dart';
import '../test/widget_test.dart' show FakeSleepPlatform;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native secure storage and SQLite preserve the AI settings and each call',
    (tester) async {
      final repository = DeviceAiRepository();
      const secrets = DeviceAiSecrets();
      final transport = FakeAiTransport()
        ..replies.addAll([
          AiHttpResponse(
            200,
            jsonEncode({
              'data': [
                {'id': 'fixture-device-model'},
              ],
            }),
          ),
          fakeResponse(),
        ]);
      final controller = AiController(
        repository: repository,
        secrets: secrets,
        client: AiClient(transport: transport),
      );
      final platform = FakeSleepPlatform()
        ..value = SleepSnapshot.fromJson({
          'sessions': [
            {
              'id': 'device-fixture',
              'nightId': currentNight(),
              'validMs': 14400000,
              'targetMs': 15000000,
              'snoreMs': 1440000,
              'strongMs': 0,
              'source': 'validation',
            },
          ],
        });
      await tester.pumpWidget(
        MianbanApp(platform: platform, aiController: controller),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('模型设置').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('ai-api-key')));
      await tester.enterText(
        find.byKey(const ValueKey('ai-api-key')),
        'fake-device-key-for-local-test',
      );
      await tester.ensureVisible(find.text('获取模型列表'));
      await tester.tap(find.text('获取模型列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('fixture-device-model').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('设置模型单价'));
      await tester.tap(find.text('设置模型单价'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('price-0')), '1');
      await tester.enterText(find.byKey(const ValueKey('price-1')), '2');
      await tester.enterText(find.byKey(const ValueKey('price-2')), '0.1');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('应用单价'));
      await tester.tap(find.text('应用单价'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存并使用'));
      await tester.tap(find.text('保存并使用'));
      await tester.pumpAndSettle();

      expect(
        await secrets.read(controller.active.credentialId!),
        'fake-device-key-for-local-test',
      );
      final savedProfiles = await repository.profiles();
      expect(
        savedProfiles.map((profile) => profile.toJson()).toString(),
        isNot(contains('fake-device-key-for-local-test')),
      );
      await tester.tap(find.text('状态'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('发送统计并分析'));
      await tester.tap(find.text('发送统计并分析'));
      await tester.pumpAndSettle();
      expect(find.text('这是一段联调分析结果。'), findsOneWidget);
      final calls = await repository.calls();
      final call = calls.firstWhere(
        (call) => call.requestedModel == 'fixture-device-model',
      );
      expect(call.status, 'success');
      expect(call.amountNano, 1020000);
      expect(call.requestId, 'request-fixture');
      expect(
        call.toJson().toString(),
        isNot(contains('fake-device-key-for-local-test')),
      );
      await tester.ensureVisible(find.text(call.costLabel));
      await tester.tap(find.text(call.costLabel));
      await tester.pumpAndSettle();
      expect(find.text('调用明细'), findsOneWidget);
      expect(find.text(call.costLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'SQLite recovers a pending call as interrupted without inventing a cost',
    (tester) async {
      final repository = DeviceAiRepository();
      final call = AiCall(
        id: aiId(),
        startedAt: DateTime.now().toUtc(),
        provider: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        protocol: AiProtocol.openaiResponses.label,
        requestedModel: 'pending-fixture',
        scope: 'interruption-fixture',
        fingerprint: 'fixture',
        status: 'pending',
      );
      await repository.writeCall(call);
      final restarted = DeviceAiRepository();
      await restarted.initialize();
      final recovered = (await restarted.calls()).singleWhere(
        (value) => value.id == call.id,
      );
      expect(recovered.status, 'interrupted');
      expect(recovered.amountNano, isNull);
    },
  );
}
