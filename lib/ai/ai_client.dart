import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_models.dart';

class AiHttpResponse {
  const AiHttpResponse(this.status, this.body, {this.headers = const {}});
  final int status;
  final String body;
  final Map<String, String> headers;
}

abstract class AiTransport {
  Future<AiHttpResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers, {
    String? body,
  });
  void close();
}

class DeviceAiTransport implements AiTransport {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  @override
  Future<AiHttpResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers, {
    String? body,
  }) {
    HttpClientRequest? request;
    var expired = false;
    Future<AiHttpResponse> perform() async {
      final next = await _client.openUrl(method, uri);
      request = next;
      if (expired) {
        next.abort();
        throw TimeoutException('连接超时');
      }
      next.followRedirects = false;
      headers.forEach(next.headers.set);
      if (body != null) next.add(utf8.encode(body));
      final response = await next.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          next.abort();
          throw const AiApiException('接口响应超过大小限制');
        }
        bytes.addAll(chunk);
      }
      return AiHttpResponse(
        response.statusCode,
        utf8.decode(bytes),
        headers: {
          for (final name in [
            'x-request-id',
            'request-id',
            'x-dashscope-request-id',
          ])
            if (response.headers.value(name) != null)
              name: response.headers.value(name)!,
        },
      );
    }

    return perform().timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        expired = true;
        request?.abort();
        throw TimeoutException('调用超时，用量与费用待供应商核对');
      },
    );
  }

  @override
  void close() => _client.close(force: true);
}

class AiApiException implements Exception {
  const AiApiException(this.message, {this.status, this.usage, this.requestId});
  final String message;
  final int? status;
  final TokenUsage? usage;
  final String? requestId;
  @override
  String toString() => message;
}

class AiReply {
  const AiReply({
    required this.text,
    required this.model,
    required this.truncated,
    this.usage,
    this.requestId,
  });
  final String text, model;
  final bool truncated;
  final TokenUsage? usage;
  final String? requestId;
}

class AiClient {
  AiClient({AiTransport? transport})
    : transport = transport ?? DeviceAiTransport();
  final AiTransport transport;

  Map<String, String> headers(AiProfile profile, String key) {
    if (key.trim().isEmpty || key.contains(RegExp(r'[\r\n]'))) {
      throw const AiApiException('请填写有效的 API Key');
    }
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      profile.auth.header: profile.auth == AiAuth.bearer
          ? 'Bearer ${key.trim()}'
          : key.trim(),
      if (profile.protocol == AiProtocol.anthropic)
        'anthropic-version': profile.anthropicVersion,
    };
  }

  Map<String, dynamic> _json(AiHttpResponse response, AiProfile profile) {
    Map<String, dynamic> value;
    try {
      value = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {
      throw AiApiException(
        response.status >= 200 && response.status < 300
            ? '接口返回了无法解析的数据'
            : _httpError(response.status),
        status: response.status,
      );
    }
    if (response.status < 200 ||
        response.status >= 300 ||
        value['error'] != null ||
        value['success'] == false) {
      throw AiApiException(
        _httpError(response.status),
        status: response.status,
        usage: value['usage'] is Map
            ? TokenUsage.fromApi(
                TokenUsage.object(value['usage']),
                profile.protocol,
              )
            : null,
        requestId: _requestId(response, value),
      );
    }
    return value;
  }

  String _httpError(int status) => switch (status) {
    401 || 403 => '鉴权或访问权限不足，请核对密钥、地域与端点（HTTP $status）',
    404 || 405 || 501 => '该端点未提供此接口（HTTP $status）',
    429 => '供应商限流或额度不足，请核对账户后手动重试（HTTP 429）',
    >= 300 && < 400 => '接口发生重定向，请填写最终 API 地址（HTTP $status）',
    _ => '供应商请求失败（HTTP $status）',
  };

  String? _requestId(AiHttpResponse response, Map<String, dynamic> value) =>
      response.headers['x-request-id'] ??
      response.headers['request-id'] ??
      response.headers['x-dashscope-request-id'] ??
      value['request_id'] as String? ??
      value['id'] as String?;

  Future<ModelCatalog> models(AiProfile profile, String key) async {
    final auth = headers(profile, key);
    if (profile.provider == AiProvider.qwen) return _qwenModels(profile, auth);
    final values = <String, AiModel>{};
    Uri uri = apiPath(profile.baseUrl, 'models');
    final seenCursors = <String>{};
    for (var page = 0; page < 30; page++) {
      Map<String, dynamic> json;
      try {
        json = _json(await transport.send('GET', uri, auth), profile);
      } on AiApiException catch (failure) {
        if (page == 0 &&
            profile.provider == AiProvider.glm &&
            [404, 405, 501].contains(failure.status)) {
          return _glmCatalog();
        }
        rethrow;
      }
      final rows = json['data'] ?? json['models'];
      if (rows is! List) throw const AiApiException('接口未返回模型列表，可手动填写型号');
      for (final row in rows.whereType<Map>()) {
        final id = row['id'] ?? row['model'] ?? row['slug'];
        if (id is String && id.isNotEmpty) {
          values[id] = AiModel(
            id,
            name: (row['display_name'] ?? row['name']) as String?,
          );
        }
      }
      if (json['has_more'] != true) return _catalog(values.values);
      final cursor =
          json['last_id'] ??
          (rows.isEmpty ? null : TokenUsage.object(rows.last)['id']);
      if (cursor is! String || !seenCursors.add(cursor)) {
        throw const AiApiException('模型列表分页未能继续');
      }
      uri = apiPath(profile.baseUrl, 'models').replace(
        queryParameters: {
          profile.protocol == AiProtocol.anthropic ? 'after_id' : 'after':
              cursor,
          'limit': '100',
        },
      );
    }
    throw const AiApiException('模型列表页数超过限制，请缩小端点的模型范围');
  }

  ModelCatalog _catalog(Iterable<AiModel> models, {String source = '供应商接口'}) {
    final values = models.toList()..sort((a, b) => a.id.compareTo(b.id));
    if (values.isEmpty) throw const AiApiException('接口返回的模型列表为空，可手动填写型号');
    return ModelCatalog(values, source: source, fetchedAt: DateTime.now());
  }

  Future<ModelCatalog> _glmCatalog() async {
    final response = await transport.send(
      'GET',
      Uri.parse('https://docs.bigmodel.cn/cn/guide/start/model-overview.md'),
      {'Accept': 'text/markdown'},
    );
    if (response.status != 200) {
      throw const AiApiException('官方模型目录暂时无法读取，可手动填写型号');
    }
    final pattern = RegExp(
      r'\[(GLM-[^\]]+)\]\(https://docs\.bigmodel\.cn/cn/guide/models/(?:text|vlm)/',
    );
    final ids = pattern
        .allMatches(response.body)
        .map((match) => match[1]!.toLowerCase())
        .toSet();
    return _catalog(ids.map(AiModel.new), source: '智谱官方模型目录 · 账户权限待调用验证');
  }

  Future<ModelCatalog> _qwenModels(
    AiProfile profile,
    Map<String, String> auth,
  ) async {
    final base = apiBase(profile.baseUrl);
    final values = <String, AiModel>{};
    var fetched = 0;
    for (var page = 1; page <= 30; page++) {
      final uri = base.replace(
        path: '/api/v1/models',
        queryParameters: {
          'providers': 'qwen',
          'capabilities': 'TG',
          'page_no': '$page',
          'page_size': '100',
        },
      );
      Map<String, dynamic> json;
      try {
        json = _json(await transport.send('GET', uri, auth), profile);
      } on AiApiException catch (failure) {
        if (page == 1 && [404, 405, 501].contains(failure.status)) {
          throw const AiApiException('请填写百炼业务空间对应的 API 基础地址后获取模型');
        }
        rethrow;
      }
      final output = TokenUsage.object(json['output']);
      final rows = output['models'];
      if (rows is! List) throw const AiApiException('百炼未返回模型列表，请核对业务空间地址');
      fetched += rows.length;
      for (final row in rows.whereType<Map>()) {
        final id = row['model'] ?? row['id'];
        if (id is String && id.isNotEmpty) {
          values[id] = AiModel(id, name: row['name'] as String?);
        }
      }
      final total = (output['total'] ?? output['total_count']) as num?;
      if (rows.isEmpty ||
          (total != null ? fetched >= total : rows.length < 100)) {
        return _catalog(values.values);
      }
    }
    throw const AiApiException('百炼模型列表页数超过限制');
  }

  Future<AiReply> analyze(
    AiProfile profile,
    String key,
    Map<String, dynamic> data,
  ) async {
    const instructions =
        '你是眠伴的鼾声记录分析助手。仅根据提供的声音统计，用简体中文、250字以内的纯文本给出观察、数据局限及1至2条可执行建议。'
        '只讨论鼾声维度，严格区分有效分析时长与睡眠时长。按实际日期与最近一次有有效分析的非测试记录比较，允许日期不连续，并注明两次实际日期。'
        '短记录、低覆盖率、不确定声音、测试数据和评分为空时说明数据不足。禁止推断睡眠分期、呼吸暂停、疾病严重程度或诊断，禁止改写给定评分。'
        '建议应温和且避免用药、器械治疗或承诺疗效。有持续困扰时可建议咨询专业人员。';
    final payload = jsonEncode(data);
    final Map<String, dynamic> body;
    switch (profile.protocol) {
      case AiProtocol.openaiResponses:
        body = {
          'model': profile.model,
          'instructions': instructions,
          'input': payload,
          'max_output_tokens': 4096,
          'store': false,
          if (profile.provider == AiProvider.openai) 'service_tier': 'default',
        };
      case AiProtocol.openaiChat:
        body = {
          'model': profile.model,
          'messages': [
            {'role': 'system', 'content': instructions},
            {'role': 'user', 'content': payload},
          ],
          'max_tokens': 4096,
          'stream': false,
        };
      case AiProtocol.anthropic:
        body = {
          'model': profile.model,
          'system': instructions,
          'messages': [
            {'role': 'user', 'content': payload},
          ],
          'max_tokens': 4096,
          'stream': false,
        };
    }
    final response = await transport.send(
      'POST',
      apiPath(profile.baseUrl, profile.protocol.path),
      headers(profile, key),
      body: jsonEncode(body),
    );
    final json = _json(response, profile);
    final usage = json['usage'] is Map
        ? TokenUsage.fromApi(TokenUsage.object(json['usage']), profile.protocol)
        : null;
    String text;
    bool truncated;
    switch (profile.protocol) {
      case AiProtocol.openaiResponses:
        final messages = (json['output'] as List? ?? []).whereType<Map>().where(
          (item) => item['type'] == 'message',
        );
        text = messages
            .expand((message) => message['content'] as List? ?? [])
            .whereType<Map>()
            .map((part) => part['text'] ?? part['refusal'] ?? '')
            .whereType<String>()
            .join('\n')
            .trim();
        truncated = json['status'] == 'incomplete';
      case AiProtocol.openaiChat:
        final choices = json['choices'] as List? ?? [];
        final choice = choices.isEmpty
            ? <String, dynamic>{}
            : TokenUsage.object(choices.first);
        final content = TokenUsage.object(choice['message'])['content'];
        text = content is String
            ? content.trim()
            : (content is List
                  ? content
                        .whereType<Map>()
                        .map((item) => item['text'] ?? '')
                        .whereType<String>()
                        .join('\n')
                        .trim()
                  : '');
        truncated = choice['finish_reason'] == 'length';
      case AiProtocol.anthropic:
        text = (json['content'] as List? ?? [])
            .whereType<Map>()
            .where((item) => item['type'] == 'text')
            .map((item) => item['text'])
            .whereType<String>()
            .join('\n')
            .trim();
        truncated = json['stop_reason'] == 'max_tokens';
    }
    return AiReply(
      text: text,
      model: json['model'] as String? ?? profile.model,
      truncated: truncated,
      usage: usage,
      requestId: _requestId(response, json),
    );
  }

  void close() => transport.close();
}
