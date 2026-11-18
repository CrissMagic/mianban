import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ai/ai_controller.dart';
import 'domain/sleep_data.dart';
import 'platform/sleep_platform.dart';
import 'sleep_controller.dart';
import 'ui/screens.dart';
import 'ui/ai_settings.dart';
import 'ui/widgets.dart';
import 'ui/recording_settings.dart';
import 'ui/update_screen.dart';

class MianbanApp extends StatefulWidget {
  const MianbanApp({super.key, this.platform, this.aiController});
  final SleepPlatform? platform;
  final AiController? aiController;
  @override
  State<MianbanApp> createState() => _MianbanAppState();
}

class _MianbanAppState extends State<MianbanApp> {
  late final SleepController controller;
  late final PlaybackController player;
  late final AiController ai;
  @override
  void initState() {
    super.initState();
    final platform = widget.platform ?? NativeSleepPlatform();
    controller = SleepController(platform);
    player = PlaybackController(platform);
    ai = widget.aiController ?? AiController();
    unawaited(controller.initialize());
    unawaited(ai.initialize());
  }

  @override
  void dispose() {
    player.dispose();
    controller.dispose();
    if (widget.aiController == null) ai.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '眠伴',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: forest,
        surface: cream,
      ).copyWith(primary: forest, onSurface: ink),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 72,
        centerTitle: false,
        titleSpacing: 24,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: paper,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
      ),
      dividerTheme: const DividerThemeData(color: line),
      chipTheme: const ChipThemeData(
        selectedColor: Color(0xffdde7d5),
        backgroundColor: cream,
        side: BorderSide(color: line),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
      ),
    ),
    home: _Home(controller: controller, player: player, ai: ai),
  );
}

class _Home extends StatefulWidget {
  const _Home({
    required this.controller,
    required this.player,
    required this.ai,
  });
  final SleepController controller;
  final PlaybackController player;
  final AiController ai;
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  static const _privacy =
      '声音使用手机麦克风采集，在本机通过YAMNet识别。录音和记录保存在应用私有目录。'
      '卸载会删除本地数据。开始时将申请麦克风和监测通知权限。首次约15秒用于环境校准，较强鼾声按高于基线12 dB估计，'
      '该值反映录音电平的相对差异。AI分析由手动触发，将所选日期的鼾声指标和数据质量发送给当前供应商，调用记录保存在设备中。';

  int selected = 0;
  void _openNight(SleepNight night) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NightDetailScreen(
          night: night,
          controller: widget.controller,
          player: widget.player,
          ai: widget.ai,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.nightlight_round, color: forest, size: 28),
            const SizedBox(width: 12),
            Text(
              ['今日', '变化趋势', '当前状态'][selected],
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                letterSpacing: -.7,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '录音设置',
            icon: const Icon(Icons.settings_voice_rounded, size: 21),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RecordingSettingsScreen(
                  platform: widget.controller.platform,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '模型设置',
            icon: const Icon(Icons.tune_rounded, size: 21),
            onPressed: () => openAiSettings(context, widget.ai),
          ),
          if (Platform.isAndroid)
            PopupMenuButton<bool>(
              tooltip: '更多',
              onSelected: (updates) {
                if (updates) {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          UpdateScreen(controller: widget.controller),
                    ),
                  );
                } else {
                  showInformation(context, '记录与隐私', _privacy);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: true, child: Text('应用更新')),
                PopupMenuItem(value: false, child: Text('记录与隐私')),
              ],
            )
          else
            const InfoButton(title: '记录与隐私', body: _privacy),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: widget.controller.loading
            ? const Center(child: CircularProgressIndicator())
            : IndexedStack(
                index: selected,
                children: [
                  TodayScreen(
                    controller: widget.controller,
                    onNight: _openNight,
                  ),
                  TrendsScreen(
                    controller: widget.controller,
                    onNight: _openNight,
                  ),
                  StatusScreen(controller: widget.controller, ai: widget.ai),
                ],
              ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: paper,
          border: Border(top: BorderSide(color: line)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 16, 9),
            child: Row(
              children: [
                for (final (index, label, icon) in [
                  (0, '今日', Icons.nightlight_round),
                  (1, '趋势', Icons.show_chart_rounded),
                  (2, '状态', Icons.donut_large_rounded),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Semantics(
                        selected: selected == index,
                        button: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(17),
                          onTap: () => setState(() => selected = index),
                          child: Container(
                            height: 62,
                            decoration: BoxDecoration(
                              color: selected == index
                                  ? const Color(0xffe8ede2)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(17),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  icon,
                                  size: 25,
                                  color: selected == index ? forest : muted,
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected == index ? forest : muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
