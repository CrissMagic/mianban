import 'dart:async';
import 'dart:convert';

import 'package:mianban/ai/ai_client.dart';
import 'package:mianban/ai/ai_models.dart';
import 'package:mianban/ai/ai_repository.dart';

class MemoryAiSecrets implements AiSecrets {
  final values = <String, String>{};
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class MemoryAiRepository implements AiRepository {
  final savedProfiles = <AiProvider, AiProfile>{};
  final savedCalls = <String, AiCall>{};
  String? selected;
  bool rejectProfile = false, rejectPending = false, rejectCompletion = false;
  @override
  Future<void> initialize() async {
    for (final call in savedCalls.values.toList()) {
      if (call.status == 'pending') {
        savedCalls[call.id] = AiCall.fromJson({
          ...call.toJson(),
          'status': 'interrupted',
        });
      }
    }
  }

  @override
  Future<List<AiProfile>> profiles() async => savedProfiles.values.toList();
  @override
  Future<String?> activeProvider() async => selected;
  @override
  Future<void> saveProfile(AiProfile profile) async {
    if (rejectProfile) throw StateError('controlled storage failure');
    savedProfiles[profile.provider] = AiProfile.fromJson(profile.toJson());
    selected = profile.provider.name;
  }

  @override
  Future<void> writeCall(AiCall call) async {
    if ((call.status == 'pending' && rejectPending) ||
        (call.status != 'pending' && rejectCompletion)) {
      throw StateError('controlled checkpoint failure');
    }
    savedCalls[call.id] = AiCall.fromJson(call.toJson());
  }

  @override
  Future<List<AiCall>> calls({int limit = 100, int offset = 0}) async {
    final sorted = savedCalls.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return sorted.skip(offset).take(limit).toList();
  }

  @override
  Future<AiCall?> latest(String scope) async => (await calls(limit: 100000))
      .where(
        (call) =>
            call.scope == scope && ['success', 'partial'].contains(call.status),
      )
      .firstOrNull;
  @override
  Future<Map<String, (BigInt, int)>> totals() async {
    final totals = <String, (BigInt, int)>{};
    for (final call in savedCalls.values) {
      final currency = call.price?.currency ?? 'unknown';
      final prior = totals[currency] ?? (BigInt.zero, 0);
      totals[currency] = (
        prior.$1 + BigInt.from(call.amountNano ?? 0),
        prior.$2 + (call.amountNano == null ? 1 : 0),
      );
    }
    return totals;
  }
}

class FakeAiTransport implements AiTransport {
  final replies = <Object>[];
  final requests =
      <({String method, Uri uri, Map<String, String> headers, String? body})>[];
  Completer<void>? gate;
  void Function()? beforeSend;
  @override
  Future<AiHttpResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers, {
    String? body,
  }) async {
    beforeSend?.call();
    requests.add((method: method, uri: uri, headers: headers, body: body));
    if (gate != null) await gate!.future;
    final reply = replies.removeAt(0);
    if (reply is AiHttpResponse) return reply;
    throw reply;
  }

  @override
  void close() {}
}

AiHttpResponse fakeResponse({
  String protocol = 'responses',
  bool truncated = false,
  bool withUsage = true,
}) => AiHttpResponse(
  200,
  jsonEncode({
    'id': 'response-fixture',
    'model': 'model-test-resolved',
    if (protocol == 'responses') ...{
      'status': truncated ? 'incomplete' : 'completed',
      'output': [
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': '这是一段联调分析结果。'},
          ],
        },
      ],
      if (withUsage)
        'usage': {
          'input_tokens': 1000,
          'output_tokens': 100,
          'input_tokens_details': {'cached_tokens': 200},
        },
    },
    if (protocol == 'chat') ...{
      'choices': [
        {
          'finish_reason': truncated ? 'length' : 'stop',
          'message': {'content': '这是一段联调分析结果。'},
        },
      ],
      if (withUsage)
        'usage': {
          'prompt_tokens': 1000,
          'completion_tokens': 100,
          'prompt_tokens_details': {'cached_tokens': 200},
        },
    },
    if (protocol == 'anthropic') ...{
      'content': [
        {'type': 'text', 'text': '这是一段联调分析结果。'},
      ],
      'stop_reason': truncated ? 'max_tokens' : 'end_turn',
      if (withUsage)
        'usage': {
          'input_tokens': 800,
          'output_tokens': 100,
          'cache_read_input_tokens': 200,
        },
    },
  }),
  headers: {'x-request-id': 'request-fixture'},
);

TokenPrice testPrice({int input = 1000000, String currency = 'USD'}) =>
    TokenPrice(
      currency: currency,
      input: input,
      output: 2000000,
      cachedInput: 100000,
      cacheWrite: 1000000,
      cacheWriteShort: 1250000,
      cacheWriteLong: 2500000,
      savedAt: DateTime.utc(2026, 11, 9),
    );
