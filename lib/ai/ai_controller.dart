import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'ai_client.dart';
import 'ai_models.dart';
import 'ai_repository.dart';

String aiError(Object failure) => switch (failure) {
  AiApiException() => failure.message,
  FormatException() => failure.message,
  TimeoutException() => '调用超时，用量与费用待供应商核对',
  SocketException() || HandshakeException() => '连接失败，请检查网络与 HTTPS 地址',
  HttpException() => 'HTTP 连接异常，请检查接口地址和鉴权设置',
  _ => '配置或调用记录保存失败，请重试',
};

class AiController extends ChangeNotifier {
  AiController({AiRepository? repository, AiSecrets? secrets, AiClient? client})
    : repository = repository ?? DeviceAiRepository(),
      secrets = secrets ?? const DeviceAiSecrets(),
      client = client ?? AiClient();
  final AiRepository repository;
  final AiSecrets secrets;
  final AiClient client;
  final Map<AiProvider, AiProfile> profiles = {};
  final Map<String, AiCall> reports = {};
  final Set<String> _reportsLoaded = {}, _reportsLoading = {};
  AiProvider activeProvider = AiProvider.openai;
  List<AiCall> calls = [];
  Map<String, (BigInt, int)> totals = {};
  String error = '';
  String? generatingScope;
  bool initialized = false,
      saving = false,
      loadingMore = false,
      hasMore = false;
  bool _disposed = false;
  Future<void>? _initializing;
  AiProfile get active => profile(activeProvider);
  bool get configured =>
      initialized && active.model.isNotEmpty && active.credentialId != null;
  AiProfile profile(AiProvider provider) =>
      profiles[provider] ?? AiProfile.defaults(provider);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      await repository.initialize();
      final saved = await repository.profiles();
      for (final value in saved) {
        profiles[value.provider] = value;
      }
      final selected = await repository.activeProvider();
      activeProvider =
          AiProvider.values
              .where((value) => value.name == selected)
              .firstOrNull ??
          AiProvider.openai;
      await reloadCalls();
      initialized = true;
      error = '';
    } catch (failure) {
      error = aiError(failure);
      _initializing = null;
    }
    _notify();
  }

  Future<ModelCatalog> fetchModels(AiProfile draft, String typedKey) async {
    final key = typedKey.trim().isNotEmpty
        ? typedKey.trim()
        : await _key(draft);
    return client.models(draft, key);
  }

  Future<String> _key(AiProfile profile) async {
    final id = profile.credentialId;
    final key = id == null ? null : await secrets.read(id);
    if (key == null || key.isEmpty) {
      throw const AiApiException('请在模型设置中填写 API Key');
    }
    final saved = this.profile(profile.provider);
    if (apiBase(saved.baseUrl).origin != apiBase(profile.baseUrl).origin) {
      throw const AiApiException('API 地址已变更，请重新填写密钥');
    }
    return key;
  }

  Future<void> save(AiProfile draft, {String newKey = ''}) async {
    if (saving) throw const AiApiException('配置正在保存');
    apiBase(draft.baseUrl);
    if (newKey.contains(RegExp(r'[\r\n]')) || newKey.length > 8192) {
      throw const AiApiException('API Key 格式无效');
    }
    if (draft.anthropicVersion.contains(RegExp(r'[\r\n]'))) {
      throw const AiApiException('API 版本格式无效');
    }
    saving = true;
    _notify();
    String? created;
    var committed = false;
    final previous = profile(draft.provider);
    try {
      if (previous.credentialId != null &&
          newKey.trim().isEmpty &&
          apiBase(previous.baseUrl).origin != apiBase(draft.baseUrl).origin) {
        throw const AiApiException('API 地址已变更，请重新填写密钥');
      }
      var credential = previous.credentialId;
      if (newKey.trim().isNotEmpty) {
        credential = aiId();
        created = credential;
        await secrets.write(credential, newKey.trim());
      }
      final saved = AiProfile(
        provider: draft.provider,
        baseUrl: apiBase(draft.baseUrl).toString(),
        protocol: draft.protocol,
        auth: draft.auth,
        anthropicVersion: draft.anthropicVersion,
        model: draft.model.trim(),
        credentialId: credential,
        catalog: draft.catalog,
        prices: Map.unmodifiable(draft.prices),
      );
      await repository.saveProfile(saved);
      committed = true;
      profiles[draft.provider] = saved;
      activeProvider = draft.provider;
      error = '';
      if (created != null && previous.credentialId != null) {
        // The committed profile already refers to the new key if cleanup fails.
        try {
          await secrets.delete(previous.credentialId!);
        } catch (_) {}
      }
    } finally {
      if (!committed && created != null) {
        try {
          await secrets.delete(created);
        } catch (_) {}
      }
      saving = false;
      _notify();
    }
  }

  static String fingerprint(Map<String, dynamic> data) =>
      sha256.convert(utf8.encode(jsonEncode(data))).toString();

  Future<void> loadReport(String scope) async {
    await initialize();
    if (!initialized ||
        _reportsLoaded.contains(scope) ||
        !_reportsLoading.add(scope)) {
      return;
    }
    try {
      final saved = await repository.latest(scope);
      if (saved != null &&
          (reports[scope] == null ||
              reports[scope]!.startedAt.isBefore(saved.startedAt))) {
        reports[scope] = saved;
      }
      _reportsLoaded.add(scope);
    } catch (failure) {
      error = aiError(failure);
    } finally {
      _reportsLoading.remove(scope);
      _notify();
    }
  }

  Future<AiCall> generate(String scope, Map<String, dynamic> data) async {
    if (generatingScope != null) throw const AiApiException('已有分析正在生成');
    await initialize();
    if (!initialized) throw const AiApiException('调用账本暂时无法打开');
    final selected = active;
    if (selected.model.isEmpty) throw const AiApiException('请先选择模型');
    apiBase(selected.baseUrl);
    final key = await _key(selected);
    client.headers(selected, key);
    if (generatingScope != null) throw const AiApiException('已有分析正在生成');
    final dataFingerprint = fingerprint(data);
    generatingScope = scope;
    error = '';
    _notify();
    final pending = AiCall(
      id: aiId(),
      startedAt: DateTime.now(),
      provider: selected.provider.label,
      baseUrl: selected.baseUrl,
      protocol: selected.protocol.label,
      requestedModel: selected.model,
      scope: scope,
      fingerprint: dataFingerprint,
      status: 'pending',
      price: selected.price,
    );
    try {
      // Persist the attempt before any billable request can leave the device.
      await repository.writeCall(pending);
      await reloadCalls();
      AiReply? reply;
      Object? failure;
      try {
        reply = await client.analyze(selected, key, data);
      } catch (caught) {
        failure = caught;
      }
      final usage =
          reply?.usage ?? (failure is AiApiException ? failure.usage : null);
      final message = failure == null
          ? (reply!.text.isEmpty
                ? '模型未返回分析文本'
                : reply.truncated
                ? '输出达到上限，可查看本次部分结果'
                : '')
          : aiError(failure);
      final completed = AiCall(
        id: pending.id,
        startedAt: pending.startedAt,
        provider: pending.provider,
        baseUrl: pending.baseUrl,
        protocol: pending.protocol,
        requestedModel: pending.requestedModel,
        scope: scope,
        fingerprint: pending.fingerprint,
        price: pending.price,
        usage: usage,
        finishedAt: DateTime.now(),
        resolvedModel: reply?.model,
        requestId:
            reply?.requestId ??
            (failure is AiApiException ? failure.requestId : null),
        status: failure != null || reply!.text.isEmpty
            ? 'failed'
            : reply.truncated
            ? 'partial'
            : 'success',
        amountNano: pending.price?.costNano(usage),
        result: reply?.text ?? '',
        error: message,
      );
      await repository.writeCall(completed);
      if (completed.result.isNotEmpty) reports[scope] = completed;
      await reloadCalls();
      error = message;
      return completed;
    } catch (failure) {
      // A failed final checkpoint leaves the durable pending attempt for recovery.
      error = aiError(failure);
      rethrow;
    } finally {
      generatingScope = null;
      _notify();
    }
  }

  Future<void> reloadCalls() async {
    calls = await repository.calls();
    totals = await repository.totals();
    hasMore = calls.length == 100;
    _notify();
  }

  Future<void> loadMore() async {
    if (loadingMore || !hasMore) return;
    loadingMore = true;
    _notify();
    try {
      final next = await repository.calls(offset: calls.length);
      calls = [...calls, ...next];
      hasMore = next.length == 100;
    } finally {
      loadingMore = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    client.close();
    super.dispose();
  }
}
