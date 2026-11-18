import 'package:flutter/material.dart';

import '../domain/sleep_data.dart';
import '../platform/sleep_platform.dart';
import '../sleep_controller.dart';
import 'widgets.dart';

class RecordingSettingsScreen extends StatefulWidget {
  const RecordingSettingsScreen({super.key, required this.platform});
  final SleepPlatform platform;
  @override
  State<RecordingSettingsScreen> createState() =>
      _RecordingSettingsScreenState();
}

class _RecordingSettingsScreenState extends State<RecordingSettingsScreen> {
  RecordingSettings? _settings;
  bool _saving = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await widget.platform.recordingSettings();
      if (mounted) setState(() => _settings = settings);
    } catch (failure) {
      if (mounted) setState(() => _error = errorMessage(failure));
    }
  }

  Future<void> _save(RecordingSettings settings) async {
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await widget.platform.saveRecordingSettings(settings);
      if (mounted) setState(() => _settings = settings);
    } catch (failure) {
      if (mounted) setState(() => _error = errorMessage(failure));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('录音设置')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (_error.isNotEmpty)
          ErrorNotice(
            message: _error,
            onDismiss: () => setState(() => _error = ''),
          ),
        if (_settings case final settings?) ...[
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Expanded(
                      child: Text(
                        '音频保存',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    InfoButton(
                      title: '音频保存',
                      body: '设置从下一次监测生效。仅保留鼾声会保存检测时段及前后约3秒。两种模式均保留整晚的分析统计。',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'full', label: Text('全程保存')),
                      ButtonSegment(value: 'snore', label: Text('仅保留鼾声')),
                    ],
                    selected: {settings.storageMode},
                    showSelectedIcon: false,
                    onSelectionChanged: _saving
                        ? null
                        : (values) => _save(
                            settings.copyWith(storageMode: values.first),
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Surface(
            child: Column(
              children: [
                const Row(
                  children: [
                    Expanded(
                      child: Text(
                        '录音音质',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    InfoButton(
                      title: '录音音质',
                      body: '清晰档为音频保留更多编码空间。节省空间约11 MB/小时，清晰约22 MB/小时，实际占用因设备和声音而异。仅保留鼾声时按保存的片段计。识别使用麦克风原始声音。',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 24000, label: Text('节省空间')),
                      ButtonSegment(value: 48000, label: Text('清晰')),
                    ],
                    selected: {settings.audioBitRate},
                    onSelectionChanged: _saving
                        ? null
                        : (values) => _save(
                            settings.copyWith(audioBitRate: values.first),
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Surface(
            child: Row(
              children: [
                const Expanded(
                  child: Text('增强录音响度', style: TextStyle(fontSize: 16)),
                ),
                const InfoButton(
                  title: '响度增强',
                  body: '新录音会自适应放大较轻的声音，最多约24 dB，并限制峰值。检测和强弱判断使用原始声音。开启后，历史原始录音回听也会尝试使用系统响度增强，效果取决于设备支持。',
                ),
                Switch(
                  value: settings.enhanceAudio,
                  onChanged: _saving
                      ? null
                      : (value) =>
                            _save(settings.copyWith(enhanceAudio: value)),
                ),
              ],
            ),
          ),
        ] else if (_error.isEmpty)
          const Center(child: CircularProgressIndicator())
        else
          TextButton(onPressed: _load, child: const Text('重新加载')),
      ],
    ),
  );
}
