import 'dart:math';

import '../domain/sleep_data.dart';

enum AiProtocol {
  openaiChat('OpenAI Chat Completions', 'chat/completions'),
  openaiResponses('OpenAI Responses', 'responses'),
  anthropic('Anthropic Messages', 'messages');

  const AiProtocol(this.label, this.path);
  final String label, path;
}

enum AiProvider {
  openai('OpenAI', 'https://api.openai.com/v1', AiProtocol.openaiResponses),
  deepseek('DeepSeek', 'https://api.deepseek.com', AiProtocol.openaiChat),
  glm('GLM', 'https://open.bigmodel.cn/api/paas/v4', AiProtocol.openaiChat),
  qwen(
    'Qwen',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    AiProtocol.openaiChat,
  ),
  mimo('MiMo', 'https://api.xiaomimimo.com/v1', AiProtocol.openaiChat),
  custom('自定义接口', '', AiProtocol.openaiChat);

  const AiProvider(this.label, this.baseUrl, this.protocol);
  final String label, baseUrl;
  final AiProtocol protocol;
}

enum AiAuth {
  bearer('Bearer', 'Authorization'),
  xApiKey('x-api-key', 'x-api-key'),
  apiKey('api-key', 'api-key');

  const AiAuth(this.label, this.header);
  final String label, header;
}

String aiId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Uri apiBase(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('请填写 HTTPS API 基础地址，移除账号、查询参数和片段');
  }
  return uri.replace(path: uri.path.replaceAll(RegExp(r'/+$'), ''));
}

Uri apiPath(String base, String path) {
  final uri = apiBase(base);
  return uri.replace(path: '${uri.path}/$path');
}

class AiModel {
  const AiModel(this.id, {this.name});
  final String id;
  final String? name;
  String get label => name == null || name == id ? id : '$name · $id';
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory AiModel.fromJson(Map<String, dynamic> json) =>
      AiModel(json['id'] as String, name: json['name'] as String?);
}

class ModelCatalog {
  const ModelCatalog(this.models, {this.source = '供应商接口', this.fetchedAt});
  final List<AiModel> models;
  final String source;
  final DateTime? fetchedAt;
  Map<String, dynamic> toJson() => {
    'models': models.map((model) => model.toJson()).toList(),
    'source': source,
    'fetchedAt': fetchedAt?.toUtc().toIso8601String(),
  };
  factory ModelCatalog.fromJson(Map<String, dynamic> json) => ModelCatalog(
    (json['models'] as List)
        .map(
          (value) => AiModel.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList(),
    source: json['source'] as String,
    fetchedAt: DateTime.tryParse(json['fetchedAt'] as String? ?? ''),
  );
}

// Prices use millionths of one currency unit per million tokens.
class TokenPrice {
  const TokenPrice({
    required this.currency,
    required this.input,
    required this.output,
    this.cachedInput,
    this.cacheWrite,
    this.cacheWriteShort,
    this.cacheWriteLong,
    required this.savedAt,
  });
  final String currency;
  final int input, output;
  final int? cachedInput, cacheWrite, cacheWriteShort, cacheWriteLong;
  final DateTime savedAt;

  static int parseRate(String text) {
    if (!RegExp(r'^\d{1,6}(\.\d{1,6})?$').hasMatch(text.trim())) {
      throw const FormatException('单价需为非负数字，最多保留6位小数');
    }
    final parts = text.trim().split('.');
    return int.parse(parts.first) * 1000000 +
        int.parse((parts.length == 1 ? '' : parts.last).padRight(6, '0'));
  }

  static String rateText(int value) {
    final fraction = (value % 1000000)
        .toString()
        .padLeft(6, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${value ~/ 1000000}${fraction.isEmpty ? '' : '.$fraction'}';
  }

  int? costNano(TokenUsage? usage) {
    if (usage == null || !usage.complete) return null;
    final components = [
      (usage.uncachedInput!, input),
      (usage.outputTokens!, output),
      (usage.cachedInput, cachedInput),
      (usage.cacheWrite, cacheWrite),
      (usage.cacheWriteShort, cacheWriteShort),
      (usage.cacheWriteLong, cacheWriteLong),
    ];
    var numerator = BigInt.zero;
    for (final (tokens, rate) in components) {
      if (tokens > 0 && rate == null) return null;
      numerator += BigInt.from(tokens) * BigInt.from(rate ?? 0);
    }
    final rounded = (numerator + BigInt.from(500)) ~/ BigInt.from(1000);
    if (rounded > BigInt.from(0x7fffffffffffffff)) return null;
    return rounded.toInt();
  }

  Map<String, dynamic> toJson() => {
    'currency': currency,
    'input': input,
    'output': output,
    'cachedInput': cachedInput,
    'cacheWrite': cacheWrite,
    'cacheWriteShort': cacheWriteShort,
    'cacheWriteLong': cacheWriteLong,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'source': '用户配置',
    'unit': 'currency/1M_tokens',
  };
  factory TokenPrice.fromJson(Map<String, dynamic> json) => TokenPrice(
    currency: json['currency'] as String,
    input: json['input'] as int,
    output: json['output'] as int,
    cachedInput: json['cachedInput'] as int?,
    cacheWrite: json['cacheWrite'] as int?,
    cacheWriteShort: json['cacheWriteShort'] as int?,
    cacheWriteLong: json['cacheWriteLong'] as int?,
    savedAt: DateTime.parse(json['savedAt'] as String),
  );
}

String moneyText(BigInt nano, String currency) {
  final whole = nano ~/ BigInt.from(1000000000);
  final fraction = (nano % BigInt.from(1000000000))
      .toString()
      .padLeft(9, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${currency == 'CNY' ? '¥' : '\$'}$whole.${fraction.padRight(2, '0')}';
}

class TokenUsage {
  const TokenUsage({
    this.inputTokens,
    this.outputTokens,
    this.cachedInput = 0,
    this.cacheWrite = 0,
    this.cacheWriteShort = 0,
    this.cacheWriteLong = 0,
    this.reasoningTokens,
    required this.raw,
  });
  final int? inputTokens, outputTokens, reasoningTokens;
  final int cachedInput, cacheWrite, cacheWriteShort, cacheWriteLong;
  final Map<String, dynamic> raw;
  int? get uncachedInput => inputTokens == null
      ? null
      : inputTokens! -
            cachedInput -
            cacheWrite -
            cacheWriteShort -
            cacheWriteLong;
  bool get complete =>
      inputTokens != null &&
      outputTokens != null &&
      uncachedInput! >= 0 &&
      cachedInput >= 0 &&
      cacheWrite >= 0 &&
      cacheWriteShort >= 0 &&
      cacheWriteLong >= 0;

  static int? count(dynamic value) =>
      value is num &&
          value.isFinite &&
          value >= 0 &&
          value <= 1000000000 &&
          value == value.roundToDouble()
      ? value.toInt()
      : null;
  static Map<String, dynamic> object(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};

  factory TokenUsage.fromApi(Map<String, dynamic> raw, AiProtocol protocol) {
    if (protocol == AiProtocol.anthropic) {
      final writes = object(raw['cache_creation']);
      final short = count(writes['ephemeral_5m_input_tokens']) ?? 0;
      final long = count(writes['ephemeral_1h_input_tokens']) ?? 0;
      final totalWrite =
          count(raw['cache_creation_input_tokens']) ?? short + long;
      final read = count(raw['cache_read_input_tokens']) ?? 0;
      final uncached = count(raw['input_tokens']);
      return TokenUsage(
        inputTokens: uncached == null ? null : uncached + read + totalWrite,
        outputTokens: count(raw['output_tokens']),
        cachedInput: read,
        cacheWrite: totalWrite - short - long,
        cacheWriteShort: short,
        cacheWriteLong: long,
        raw: raw,
      );
    }
    final details = object(
      raw['input_tokens_details'] ?? raw['prompt_tokens_details'],
    );
    final writes = object(details['cache_write_tokens_details']);
    final short = count(writes['ttl_30m_tokens']) ?? 0;
    final long = count(writes['ttl_12h_tokens']) ?? 0;
    final totalWrite = count(details['cache_write_tokens']) ?? short + long;
    final read =
        count(details['cached_tokens'] ?? raw['prompt_cache_hit_tokens']) ?? 0;
    final miss = count(raw['prompt_cache_miss_tokens']);
    return TokenUsage(
      inputTokens:
          count(raw['input_tokens'] ?? raw['prompt_tokens']) ??
          (miss == null ? null : miss + read),
      outputTokens: count(raw['output_tokens'] ?? raw['completion_tokens']),
      cachedInput: read,
      cacheWrite: totalWrite - short - long,
      cacheWriteShort: short,
      cacheWriteLong: long,
      reasoningTokens: count(
        object(
          raw['output_tokens_details'] ?? raw['completion_tokens_details'],
        )['reasoning_tokens'],
      ),
      raw: raw,
    );
  }

  Map<String, dynamic> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cachedInput': cachedInput,
    'cacheWrite': cacheWrite,
    'cacheWriteShort': cacheWriteShort,
    'cacheWriteLong': cacheWriteLong,
    'reasoningTokens': reasoningTokens,
    'raw': raw,
  };
  factory TokenUsage.fromJson(Map<String, dynamic> json) => TokenUsage(
    inputTokens: json['inputTokens'] as int?,
    outputTokens: json['outputTokens'] as int?,
    cachedInput: json['cachedInput'] as int,
    cacheWrite: json['cacheWrite'] as int,
    cacheWriteShort: json['cacheWriteShort'] as int,
    cacheWriteLong: json['cacheWriteLong'] as int,
    reasoningTokens: json['reasoningTokens'] as int?,
    raw: object(json['raw']),
  );
}

class AiProfile {
  const AiProfile({
    required this.provider,
    required this.baseUrl,
    required this.protocol,
    this.auth = AiAuth.bearer,
    this.anthropicVersion = '2023-06-01',
    this.model = '',
    this.credentialId,
    this.catalog = const ModelCatalog([]),
    this.prices = const {},
  });
  factory AiProfile.defaults(AiProvider provider) => AiProfile(
    provider: provider,
    baseUrl: provider.baseUrl,
    protocol: provider.protocol,
    auth: provider == AiProvider.mimo ? AiAuth.apiKey : AiAuth.bearer,
  );
  final AiProvider provider;
  final String baseUrl, model;
  final String? credentialId;
  final AiProtocol protocol;
  final AiAuth auth;
  final String anthropicVersion;
  final ModelCatalog catalog;
  final Map<String, TokenPrice> prices;
  TokenPrice? get price => prices[model];
  AiProfile copyWith({
    String? baseUrl,
    String? model,
    AiProtocol? protocol,
    AiAuth? auth,
    String? anthropicVersion,
    ModelCatalog? catalog,
    Map<String, TokenPrice>? prices,
  }) => AiProfile(
    provider: provider,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    credentialId: credentialId,
    protocol: protocol ?? this.protocol,
    auth: auth ?? this.auth,
    anthropicVersion: anthropicVersion ?? this.anthropicVersion,
    catalog: catalog ?? this.catalog,
    prices: prices ?? this.prices,
  );
  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'baseUrl': baseUrl,
    'protocol': protocol.name,
    'model': model,
    'credentialId': credentialId,
    'auth': auth.name,
    'anthropicVersion': anthropicVersion,
    'catalog': catalog.toJson(),
    'prices': prices.map((key, value) => MapEntry(key, value.toJson())),
  };
  factory AiProfile.fromJson(Map<String, dynamic> json) => AiProfile(
    provider: AiProvider.values.byName(json['provider'] as String),
    baseUrl: json['baseUrl'] as String,
    protocol: AiProtocol.values.byName(json['protocol'] as String),
    model: json['model'] as String,
    credentialId: json['credentialId'] as String?,
    auth: AiAuth.values.byName(json['auth'] as String? ?? 'bearer'),
    anthropicVersion: json['anthropicVersion'] as String? ?? '2023-06-01',
    catalog: ModelCatalog.fromJson(TokenUsage.object(json['catalog'])),
    prices: TokenUsage.object(json['prices']).map(
      (key, value) =>
          MapEntry(key, TokenPrice.fromJson(TokenUsage.object(value))),
    ),
  );
}

class AiCall {
  const AiCall({
    required this.id,
    required this.startedAt,
    required this.provider,
    required this.baseUrl,
    required this.protocol,
    required this.requestedModel,
    required this.scope,
    required this.fingerprint,
    required this.status,
    this.price,
    this.usage,
    this.finishedAt,
    this.resolvedModel,
    this.requestId,
    this.amountNano,
    this.result = '',
    this.error = '',
  });
  final String id,
      provider,
      baseUrl,
      protocol,
      requestedModel,
      scope,
      fingerprint,
      status;
  final String? resolvedModel, requestId;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final TokenPrice? price;
  final TokenUsage? usage;
  final int? amountNano;
  final String result, error;
  String get costLabel => amountNano == null
      ? '费用待核对'
      : '${moneyText(BigInt.from(amountNano!), price!.currency)} 估算';
  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'provider': provider,
    'baseUrl': baseUrl,
    'protocol': protocol,
    'requestedModel': requestedModel,
    'scope': scope,
    'fingerprint': fingerprint,
    'status': status,
    'price': price?.toJson(),
    'usage': usage?.toJson(),
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'resolvedModel': resolvedModel,
    'requestId': requestId,
    'amountNano': amountNano,
    'result': result,
    'error': error,
  };
  factory AiCall.fromJson(Map<String, dynamic> json) => AiCall(
    id: json['id'] as String,
    startedAt: DateTime.parse(json['startedAt'] as String),
    provider: json['provider'] as String,
    baseUrl: json['baseUrl'] as String,
    protocol: json['protocol'] as String,
    requestedModel: json['requestedModel'] as String,
    scope: json['scope'] as String,
    fingerprint: json['fingerprint'] as String,
    status: json['status'] as String,
    price: json['price'] == null
        ? null
        : TokenPrice.fromJson(TokenUsage.object(json['price'])),
    usage: json['usage'] == null
        ? null
        : TokenUsage.fromJson(TokenUsage.object(json['usage'])),
    finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
    resolvedModel: json['resolvedModel'] as String?,
    requestId: json['requestId'] as String?,
    amountNano: json['amountNano'] as int?,
    result: json['result'] as String? ?? '',
    error: json['error'] as String? ?? '',
  );
}

Map<String, dynamic> analysisData(List<SleepNight> nights) => {
  'dimension': 'snoring',
  'nights': nights
      .map(
        (night) => {
          'date': night.id,
          'validAnalysisMs': night.validMs,
          'snoreMs': night.snoreMs,
          'strongSnoreMs': night.strongMs,
          'uncertainMs': night.uncertainMs,
          'coverage': night.coverage,
          'experimentalSnoreScore': night.score,
          'includesValidationData': night.validation,
        },
      )
      .toList(),
};
