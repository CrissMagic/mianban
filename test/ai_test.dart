import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mianban/ai/ai_client.dart';
import 'package:mianban/ai/ai_controller.dart';
import 'package:mianban/ai/ai_models.dart';

import 'ai_test_support.dart';

void main() {
  group('token accounting', () {
    test('chat, DeepSeek, Responses and Anthropic count cache reads once', () {
      final usages = [
        TokenUsage.fromApi({
          'prompt_tokens': 1000,
          'completion_tokens': 100,
          'prompt_tokens_details': {'cached_tokens': 200},
          'completion_tokens_details': {'reasoning_tokens': 40},
        }, AiProtocol.openaiChat),
        TokenUsage.fromApi({
          'prompt_tokens': 1000,
          'completion_tokens': 100,
          'prompt_cache_hit_tokens': 200,
          'prompt_cache_miss_tokens': 800,
        }, AiProtocol.openaiChat),
        TokenUsage.fromApi({
          'input_tokens': 1000,
          'output_tokens': 100,
          'input_tokens_details': {'cached_tokens': 200},
        }, AiProtocol.openaiResponses),
        TokenUsage.fromApi({
          'input_tokens': 800,
          'output_tokens': 100,
          'cache_read_input_tokens': 200,
        }, AiProtocol.anthropic),
      ];
      for (final usage in usages) {
        expect(usage.inputTokens, 1000);
        expect(usage.uncachedInput, 800);
        expect(testPrice().costNano(usage), 1020000);
      }
      expect(usages.first.reasoningTokens, 40);
    });
    test(
      'Anthropic cache writes add to total input and retain TTL pricing',
      () {
        final usage = TokenUsage.fromApi({
          'input_tokens': 800,
          'output_tokens': 100,
          'cache_read_input_tokens': 200,
          'cache_creation_input_tokens': 100,
          'cache_creation': {
            'ephemeral_5m_input_tokens': 100,
            'ephemeral_1h_input_tokens': 0,
          },
        }, AiProtocol.anthropic);
        expect(usage.inputTokens, 1100);
        expect(testPrice().costNano(usage), 1145000);
      },
    );
    test('Responses cache writes are included in total input', () {
      final usage = TokenUsage.fromApi({
        'input_tokens': 12000,
        'output_tokens': 900,
        'input_tokens_details': {
          'cached_tokens': 4000,
          'cache_write_tokens': 7000,
          'cache_write_tokens_details': {
            'ttl_30m_tokens': 3000,
            'ttl_12h_tokens': 4000,
          },
        },
      }, AiProtocol.openaiResponses);
      expect(usage.uncachedInput, 1000);
      expect(testPrice().costNano(usage), 16950000);
    });
    test('missing usage, missing cache price and inconsistent buckets stay unknown', () {
      final noPrice = TokenPrice(
        currency: 'CNY',
        input: 1,
        output: 1,
        savedAt: DateTime.utc(2026),
      );
      final cached = TokenUsage.fromApi({
        'input_tokens': 100,
        'output_tokens': 0,
        'input_tokens_details': {'cached_tokens': 10},
      }, AiProtocol.openaiResponses);
      expect(noPrice.costNano(cached), isNull);
      expect(testPrice().costNano(null), isNull);
      expect(
        testPrice().costNano(TokenUsage.fromApi({}, AiProtocol.openaiChat)),
        isNull,
      );
      expect(
        testPrice().costNano(
          TokenUsage.fromApi({
            'input_tokens': 100,
            'output_tokens': 1,
            'input_tokens_details': {
              'cache_write_tokens': 100,
              'cache_write_tokens_details': {'ttl_30m_tokens': 200},
            },
          }, AiProtocol.openaiResponses),
        ),
        isNull,
      );
    });
    test(
      'rates use exact decimal integers and display nanos without float drift',
      () {
        expect(TokenPrice.parseRate('0.000001'), 1);
        expect(
          TokenPrice.rateText(TokenPrice.parseRate('12.340001')),
          '12.340001',
        );
        expect(moneyText(BigInt.from(1020000), 'USD'), '\$0.00102');
        expect(moneyText(BigInt.zero, 'CNY'), '¥0.00');
        for (final value in ['-1', 'NaN', '1e3', '0.0000001']) {
          expect(() => TokenPrice.parseRate(value), throwsFormatException);
        }
      },
    );
  });

  group('provider protocols', () {
    test(
      'all fixed suppliers have presets and custom supports three protocols',
      () {
        for (final provider in AiProvider.values.where(
          (value) => value != AiProvider.custom,
        )) {
          final profile = AiProfile.defaults(provider);
          expect(apiBase(profile.baseUrl).scheme, 'https');
        }
        expect(AiProtocol.values.length, 3);
        expect(AiProfile.defaults(AiProvider.mimo).auth, AiAuth.apiKey);
      },
    );
    test('base URLs preserve prefixes and reject embedded credentials and query keys', () {
      expect(
        apiPath('https://example.com/prefix/v1/', 'messages').toString(),
        'https://example.com/prefix/v1/messages',
      );
      for (final value in [
        'http://example.com/v1',
        'https://secret@example.com/v1',
        'https://example.com/v1?key=test',
        'https://example.com/v1#test',
      ]) {
        expect(() => apiBase(value), throwsFormatException);
      }
    });
    for (final protocol in AiProtocol.values) {
      test('request and response contract for ${protocol.name}', () async {
        final transport = FakeAiTransport()
          ..replies.add(
            fakeResponse(
              protocol: switch (protocol) {
                AiProtocol.openaiChat => 'chat',
                AiProtocol.openaiResponses => 'responses',
                AiProtocol.anthropic => 'anthropic',
              },
            ),
          );
        final profile = AiProfile.defaults(AiProvider.custom).copyWith(
          baseUrl: 'https://example.com/v1',
          model: 'fixture-model',
          protocol: protocol,
          auth: protocol == AiProtocol.anthropic
              ? AiAuth.xApiKey
              : AiAuth.bearer,
        );
        final reply = await AiClient(transport: transport).analyze(
          profile,
          'test-only-key',
          {'dimension': 'snoring', 'nights': []},
        );
        expect(reply.text, '这是一段联调分析结果。');
        expect(reply.requestId, 'request-fixture');
        expect(reply.usage!.inputTokens, 1000);
        final request = transport.requests.single;
        expect(request.uri.path, '/v1/${protocol.path}');
        final body = jsonDecode(request.body!) as Map;
        expect(body['model'], 'fixture-model');
        expect(body.containsKey('temperature'), isFalse);
        if (protocol == AiProtocol.anthropic) {
          expect(request.headers['x-api-key'], 'test-only-key');
          expect(request.headers['anthropic-version'], '2023-06-01');
          expect(body['system'], isA<String>());
        }
      });
    }
    test(
      'Anthropic model discovery follows pagination and deduplicates IDs',
      () async {
        final transport = FakeAiTransport()
          ..replies.addAll([
            AiHttpResponse(
              200,
              jsonEncode({
                'data': [
                  {'id': 'a', 'display_name': 'A'},
                ],
                'has_more': true,
                'last_id': 'a',
              }),
            ),
            AiHttpResponse(
              200,
              jsonEncode({
                'data': [
                  {'id': 'a'},
                  {'id': 'b'},
                ],
                'has_more': false,
              }),
            ),
          ]);
        final profile = AiProfile.defaults(AiProvider.custom).copyWith(
          baseUrl: 'https://example.com/v1',
          protocol: AiProtocol.anthropic,
          auth: AiAuth.xApiKey,
        );
        final catalog = await AiClient(transport: transport)
            .models(profile, 'test-key');
        expect(catalog.models.map((model) => model.id), ['a', 'b']);
        expect(transport.requests.last.uri.queryParameters['after_id'], 'a');
      },
    );
    test('Qwen uses native model discovery and workspace origin', () async {
      final transport = FakeAiTransport()
        ..replies.add(
          AiHttpResponse(
            200,
            jsonEncode({
              'success': true,
              'output': {
                'total': 1,
                'models': [
                  {'model': 'qwen-fixture', 'name': 'Qwen Fixture'},
                ],
              },
            }),
          ),
        );
      final profile = AiProfile.defaults(AiProvider.qwen).copyWith(
        baseUrl:
            'https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
      );
      final catalog = await AiClient(transport: transport)
          .models(profile, 'test-key');
      expect(catalog.models.single.id, 'qwen-fixture');
      expect(transport.requests.single.uri.path, '/api/v1/models');
      expect(
        transport.requests.single.uri.queryParameters['providers'],
        'qwen',
      );
    });
    test(
      'GLM fallback reads official catalog without forwarding the API key',
      () async {
        final transport = FakeAiTransport()
          ..replies.addAll([
            const AiHttpResponse(404, '{}'),
            const AiHttpResponse(
              200,
              '[GLM-Fixture](https://docs.bigmodel.cn/cn/guide/models/text/glm-fixture.md)',
            ),
          ]);
        final catalog = await AiClient(transport: transport)
            .models(AiProfile.defaults(AiProvider.glm), 'test-only-key');
        expect(catalog.models.single.id, 'glm-fixture');
        expect(catalog.source, contains('官方'));
        expect(
          transport.requests.last.headers.containsKey('Authorization'),
          isFalse,
        );
      },
    );
    test('an authentication failure never becomes an apparently valid fallback list', () async {
      final transport = FakeAiTransport()
        ..replies.add(const AiHttpResponse(401, '{}'));
      await expectLater(
        AiClient(transport: transport)
            .models(AiProfile.defaults(AiProvider.glm), 'test-key'),
        throwsA(isA<AiApiException>()),
      );
      expect(transport.requests.length, 1);
    });
  });

  group('durable call ledger', () {
    late MemoryAiRepository repository;
    late MemoryAiSecrets secrets;
    late FakeAiTransport transport;
    late AiController controller;
    setUp(() async {
      repository = MemoryAiRepository();
      secrets = MemoryAiSecrets();
      transport = FakeAiTransport();
      controller = AiController(
        repository: repository,
        secrets: secrets,
        client: AiClient(transport: transport),
      );
      await controller.initialize();
      await controller.save(
        AiProfile.defaults(AiProvider.openai).copyWith(
          model: 'fixture-model',
          prices: {'fixture-model': testPrice()},
        ),
        newKey: 'test-only-secret',
      );
    });
    tearDown(() => controller.dispose());
    test('the pending attempt exists before POST and a price change preserves history', () async {
      transport.replies.add(fakeResponse());
      transport.beforeSend = () =>
          expect(repository.savedCalls.values.single.status, 'pending');
      final call = await controller.generate('night:2026-11-08', {
        'nights': [],
      });
      expect(call.amountNano, 1020000);
      expect(call.status, 'success');
      expect(call.resolvedModel, 'model-test-resolved');
      expect(call.toJson().toString(), isNot(contains('test-only-secret')));
      await controller.save(
        controller.active.copyWith(
          prices: {'fixture-model': testPrice(input: 9000000)},
        ),
      );
      expect(repository.savedCalls[call.id]!.price!.input, 1000000);
      expect(repository.savedCalls[call.id]!.amountNano, 1020000);
    });
    test('failure to reserve a call prevents network transmission', () async {
      repository.rejectPending = true;
      await expectLater(controller.generate('scope', {}), throwsStateError);
      expect(transport.requests, isEmpty);
      expect(controller.generatingScope, isNull);
    });
    test('a timeout is one attempt with unknown usage and cost', () async {
      transport.replies.add(TimeoutException('controlled timeout'));
      final call = await controller.generate('scope', {});
      expect(call.status, 'failed');
      expect(call.amountNano, isNull);
      expect(transport.requests.length, 1);
      expect(repository.savedCalls.length, 1);
    });
    test('successful text with absent usage retains unknown cost', () async {
      transport.replies.add(fakeResponse(withUsage: false));
      final call = await controller.generate('scope', {});
      expect(call.status, 'success');
      expect(call.result, isNotEmpty);
      expect(call.amountNano, isNull);
    });
    test('truncation retains the text and billable returned usage', () async {
      transport.replies.add(fakeResponse(truncated: true));
      final call = await controller.generate('scope', {});
      expect(call.status, 'partial');
      expect(call.amountNano, 1020000);
    });
    test('a rejected profile save rolls back the new key reference', () async {
      final oldId = controller.active.credentialId;
      repository.rejectProfile = true;
      await expectLater(
        controller.save(controller.active, newKey: 'new-test-secret'),
        throwsStateError,
      );
      expect(controller.active.credentialId, oldId);
      expect(secrets.values, {oldId: 'test-only-secret'});
    });
    test('changing custom origin requires an explicitly entered key', () async {
      final profile = AiProfile.defaults(AiProvider.custom)
          .copyWith(baseUrl: 'https://first.example/v1', model: 'test');
      await controller.save(profile, newKey: 'first-test-key');
      final changed = controller.active.copyWith(
        baseUrl: 'https://second.example/v1',
      );
      await expectLater(
        controller.fetchModels(changed, ''),
        throwsA(isA<AiApiException>()),
      );
      await expectLater(
        controller.save(changed),
        throwsA(isA<AiApiException>()),
      );
      expect(transport.requests, isEmpty);
    });
    test('double taps share no concurrent billable request', () async {
      transport.gate = Completer<void>();
      transport.replies.add(fakeResponse());
      final first = controller.generate('one', {});
      while (transport.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(
        controller.generate('two', {}),
        throwsA(isA<AiApiException>()),
      );
      transport.gate!.complete();
      await first;
      expect(transport.requests.length, 1);
    });
    test(
      'a lost final checkpoint recovers as interrupted with unknown cost',
      () async {
        repository.rejectCompletion = true;
        transport.replies.add(fakeResponse());
        await expectLater(controller.generate('scope', {}), throwsStateError);
        expect(repository.savedCalls.values.single.status, 'pending');
        repository.rejectCompletion = false;
        final restarted = AiController(
          repository: repository,
          secrets: secrets,
          client: AiClient(transport: transport),
        );
        await restarted.initialize();
        expect(restarted.calls.single.status, 'interrupted');
        expect(restarted.calls.single.amountNano, isNull);
        restarted.dispose();
      },
    );
  });
}
