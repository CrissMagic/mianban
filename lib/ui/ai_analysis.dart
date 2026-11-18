import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_models.dart';
import '../domain/sleep_data.dart';
import 'ai_settings.dart';
import 'ai_usage.dart';
import 'widgets.dart';

class AiAnalysisCard extends StatefulWidget {
  const AiAnalysisCard({
    super.key,
    required this.controller,
    required this.scope,
    required this.nights,
  });
  final AiController controller;
  final String scope;
  final List<SleepNight> nights;
  @override
  State<AiAnalysisCard> createState() => _AiAnalysisCardState();
}

class _AiAnalysisCardState extends State<AiAnalysisCard> {
  String _error = '';
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.loadReport(widget.scope));
  }

  @override
  void didUpdateWidget(covariant AiAnalysisCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _error = '';
      unawaited(widget.controller.loadReport(widget.scope));
    }
  }

  Future<void> _generate() async {
    setState(() => _error = '');
    try {
      final result = await widget.controller.generate(
        widget.scope,
        analysisData(widget.nights),
      );
      if (mounted) setState(() => _error = result.error);
    } catch (failure) {
      if (mounted) setState(() => _error = aiError(failure));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final report = controller.reports[widget.scope];
      final busy = controller.generatingScope != null;
      final changed =
          report != null &&
          report.fingerprint !=
              AiController.fingerprint(analysisData(widget.nights));
      return Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.auto_awesome_outlined,
                  color: forest,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'AI 分析',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                const InfoButton(
                  title: 'AI 分析与费用',
                  body:
                      '点击后，将所选日期及对比日期的鼾声指标、数据质量与已有实验评分发送给当前供应商。'
                      '每次调用单独记录 Token 用量与费用估算。分析由所选大模型生成，可结合回听和自己的情况核对。',
                ),
                IconButton(
                  tooltip: '模型设置',
                  icon: const Icon(Icons.tune_rounded, color: muted, size: 20),
                  onPressed: () => openAiSettings(context, controller),
                ),
              ],
            ),
            if (report != null) ...[
              const SizedBox(height: 10),
              Text(
                '${report.provider} · ${report.resolvedModel ?? report.requestedModel}',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
              const SizedBox(height: 14),
              SelectableText(
                report.result,
                style: const TextStyle(fontSize: 14, height: 1.9),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (changed)
                    const Expanded(
                      child: Text(
                        '数据已更新',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    )
                  else
                    const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => AiCallScreen(call: report),
                      ),
                    ),
                    child: Text(
                      report.costLabel,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ] else if (!controller.configured) ...[
              const SizedBox(height: 12),
              const Text(
                '选择供应商和型号后，可生成分析。',
                style: TextStyle(fontSize: 13, color: muted),
              ),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              ErrorNotice(
                message: _error,
                onDismiss: () => setState(() => _error = ''),
              ),
            ],
            const SizedBox(height: 16),
            PrimaryButton(
              label: !controller.configured
                  ? '配置模型'
                  : busy
                  ? '正在分析'
                  : '发送统计并分析',
              secondary: true,
              onPressed:
                  busy || (controller.configured && widget.nights.isEmpty)
                  ? null
                  : controller.configured
                  ? _generate
                  : () => openAiSettings(context, controller),
            ),
          ],
        ),
      );
    },
  );
}
