import 'dart:convert';

import 'package:flutter/material.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_models.dart';
import 'widgets.dart';

String callTime(DateTime date) {
  final value = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}/${two(value.month)}/${two(value.day)} ${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

const callStatuses = {
  'pending': '调用中',
  'success': '已完成',
  'partial': '输出截断',
  'failed': '调用失败',
  'interrupted': '意外中断',
};

class AiUsageScreen extends StatefulWidget {
  const AiUsageScreen({super.key, required this.controller});
  final AiController controller;
  @override
  State<AiUsageScreen> createState() => _AiUsageScreenState();
}

class _AiUsageScreenState extends State<AiUsageScreen> {
  String _error = '';
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.controller.initialize();
      await widget.controller.reloadCalls();
    } catch (failure) {
      _error = aiError(failure);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _more() async {
    try {
      await widget.controller.loadMore();
    } catch (failure) {
      if (mounted) setState(() => _error = aiError(failure));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final unknown = controller.totals.values.fold(
        0,
        (sum, value) => sum + value.$2,
      );
      return Scaffold(
        appBar: AppBar(
          title: const Text('调用记录'),
          actions: const [
            InfoButton(
              title: '费用口径',
              body:
                  '每次生成记录供应商、协议、型号、时间、返回用量及当时配置的单价。金额为 Token 项估算，按币种分别累计。'
                  '缺少完整用量或适用单价时，标为待核对。超时与中断可能已产生供应商费用，最终金额以供应商账单为准。',
            ),
            SizedBox(width: 12),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (_error.isNotEmpty)
                      ErrorNotice(
                        message: _error,
                        onDismiss: () => setState(() => _error = ''),
                      ),
                    if (controller.calls.isEmpty) ...[
                      const SizedBox(height: 80),
                      const Center(
                        child: Text(
                          '生成分析后，这里会保存每次调用。',
                          style: TextStyle(color: muted),
                        ),
                      ),
                      const SizedBox(height: 28),
                      PrimaryButton(
                        label: '返回模型设置',
                        onPressed: () => Navigator.pop(context),
                      ),
                    ] else ...[
                      Surface(
                        color: sage,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '累计估算',
                              style: TextStyle(fontSize: 14, color: muted),
                            ),
                            const SizedBox(height: 12),
                            for (final entry in controller.totals.entries.where(
                              (entry) => entry.key != 'unknown',
                            ))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  moneyText(entry.value.$1, entry.key),
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            if (unknown > 0)
                              Text(
                                '$unknown次费用待核对',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      for (final call in controller.calls) ...[
                        Surface(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                            title: Text(
                              '${call.provider} · ${call.requestedModel}',
                              style: const TextStyle(fontSize: 14),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '${callTime(call.startedAt)}\n${callStatuses[call.status] ?? call.status} · ${call.costLabel}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.8,
                                  color: muted,
                                ),
                              ),
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => AiCallScreen(call: call),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (controller.hasMore)
                        PrimaryButton(
                          label: controller.loadingMore ? '正在加载' : '加载更多记录',
                          secondary: true,
                          onPressed: controller.loadingMore ? null : _more,
                        ),
                    ],
                  ],
                ),
              ),
      );
    },
  );
}

class AiCallScreen extends StatelessWidget {
  const AiCallScreen({super.key, required this.call});
  final AiCall call;
  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: const TextStyle(color: muted, fontSize: 13),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final usage = call.usage, price = call.price;
    String rate(int? value) => value == null || price == null
        ? '—'
        : '${TokenPrice.rateText(value)} ${price.currency}/百万Token';
    return Scaffold(
      appBar: AppBar(title: const Text('调用明细')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        children: [
          Surface(
            color: sage,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  call.costLabel,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  callStatuses[call.status] ?? call.status,
                  style: const TextStyle(color: muted),
                ),
                if (call.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      call.error,
                      style: const TextStyle(fontSize: 13, color: muted),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Surface(
            child: Column(
              children: [
                _row('供应商', call.provider),
                _row('请求型号', call.requestedModel),
                _row('返回型号', call.resolvedModel ?? '—'),
                _row('接口协议', call.protocol),
                _row('API 地址', call.baseUrl),
                _row('开始时间', callTime(call.startedAt)),
                _row(
                  '耗时',
                  call.finishedAt == null
                      ? '—'
                      : '${(call.finishedAt!.difference(call.startedAt).inMilliseconds / 1000).toStringAsFixed(2)}秒',
                ),
                _row('请求编号', call.requestId ?? '—'),
                _row('本地编号', call.id),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Token 用量',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 20),
                _row('输入总量', '${usage?.inputTokens ?? '—'}'),
                _row('输出总量', '${usage?.outputTokens ?? '—'}'),
                _row('缓存读取', '${usage?.cachedInput ?? '—'}'),
                _row('普通缓存写入', '${usage?.cacheWrite ?? '—'}'),
                _row('短档缓存写入', '${usage?.cacheWriteShort ?? '—'}'),
                _row('长档缓存写入', '${usage?.cacheWriteLong ?? '—'}'),
                _row('思考Token', '${usage?.reasoningTokens ?? '—'}'),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '调用时单价',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 20),
                _row('输入', rate(price?.input)),
                _row('输出', rate(price?.output)),
                _row('缓存读取', rate(price?.cachedInput)),
                _row('普通写入', rate(price?.cacheWrite)),
                _row('短档写入', rate(price?.cacheWriteShort)),
                _row('长档写入', rate(price?.cacheWriteLong)),
                if (price != null) _row('配置时间', callTime(price.savedAt)),
              ],
            ),
          ),
          if (call.result.isNotEmpty) ...[
            const SizedBox(height: 20),
            Surface(
              child: SelectableText(
                call.result,
                style: const TextStyle(height: 1.8),
              ),
            ),
          ],
          if (usage != null)
            ExpansionTile(
              title: const Text('原始用量', style: TextStyle(fontSize: 14)),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(usage.raw),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
