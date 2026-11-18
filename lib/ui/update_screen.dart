import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sleep_controller.dart';
import '../update/github_updates.dart';
import 'widgets.dart';

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key, required this.controller});

  final SleepController controller;

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  static const _bridge = MethodChannel('mianban/update');
  static const _repository = String.fromEnvironment(
    'MIANBAN_UPDATE_REPOSITORY',
  );
  final _updates = GitHubUpdates(_repository);
  AndroidUpdate? _release;
  String _version = '';
  String _message = '';
  File? _apk;
  int _versionCode = 0;
  int? _progress;
  bool _busy = false;
  bool _downloaded = false;

  @override
  void initState() {
    super.initState();
    _version = widget.controller.snapshot.version;
    unawaited(_run(_loadInstalledVersion));
  }

  Future<void> _loadInstalledVersion() async {
    final details = await _bridge.invokeMapMethod<String, dynamic>('info');
    if (details == null || !mounted) return;
    setState(() {
      _version = details['versionName'] as String;
      _versionCode = details['versionCode'] as int;
      _apk = File(details['apkPath'] as String);
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = switch (error) {
            UpdateFailure(:final message) => message,
            PlatformException(:final message) => message ?? '更新操作未完成，请重试',
            FileSystemException() => '无法保存安装包，请检查可用空间',
            TimeoutException() ||
            SocketException() ||
            HandshakeException() ||
            HttpException() => '无法连接 GitHub，请检查网络后重试',
            _ => '暂时无法完成更新，请重试',
          };
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _check() => _run(() async {
    if (_versionCode == 0) await _loadInstalledVersion();
    if (!mounted) return;
    if (_versionCode == 0) throw const UpdateFailure('无法读取当前版本');
    final release = await _updates.check(_versionCode);
    if (!mounted) return;
    setState(() {
      if (_release?.sha256Hex != release?.sha256Hex) _downloaded = false;
      _release = release;
      if (release == null) _message = '已是最新版本';
    });
  });

  Future<void> _download(AndroidUpdate release) => _run(() async {
    setState(() => _progress = 0);
    await _updates.download(release, _apk!, (value) {
      if (mounted && _progress != value) setState(() => _progress = value);
    });
    if (mounted) setState(() => _downloaded = true);
  });

  Future<void> _install(AndroidUpdate release) => _run(() async {
    if (!await _apk!.exists()) {
      if (mounted) setState(() => _downloaded = false);
      throw const UpdateFailure('安装包已清理，请重新下载');
    }
    if (!mounted) return;
    final outcome = await _bridge.invokeMethod<String>('install', {
      'versionCode': release.versionCode,
      'versionName': release.versionName,
    });
    if (mounted && outcome == 'permission') {
      setState(() => _message = '授权此来源安装后，返回安装更新。');
    }
  });

  @override
  void dispose() {
    _updates.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('应用更新')),
    body: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final monitoring =
            widget.controller.active != null || widget.controller.busy;
        final release = _release;
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前版本 $_version',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  if (_repository.isEmpty)
                    const Text('此版本尚未配置更新源', style: TextStyle(color: muted))
                  else
                    PrimaryButton(
                      label: '检查更新',
                      onPressed: _busy ? null : _check,
                    ),
                ],
              ),
            ),
            if (release != null) ...[
              const SizedBox(height: 16),
              Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '版本 ${release.versionName}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${(release.bytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                      style: const TextStyle(color: muted),
                    ),
                    if (_progress case final progress?) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        value: progress / 100,
                        semanticsLabel: '下载进度',
                      ),
                    ],
                    const SizedBox(height: 16),
                    PrimaryButton(
                      label: _progress != null
                          ? '正在下载 $_progress%'
                          : (_downloaded ? '安装更新' : '下载安装包'),
                      onPressed: _busy || monitoring
                          ? null
                          : () => _downloaded
                                ? _install(release)
                                : _download(release),
                    ),
                    if (monitoring) ...[
                      const SizedBox(height: 10),
                      const Text(
                        '结束并保存监测后可更新。',
                        style: TextStyle(color: muted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (_message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_message, style: const TextStyle(color: muted)),
              ),
          ],
        );
      },
    ),
  );
}
