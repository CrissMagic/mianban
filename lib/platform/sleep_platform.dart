import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/sleep_data.dart';

abstract class SleepPlatform {
  Future<SleepSnapshot> snapshot();
  Future<SessionDetail> detail(String sessionId);
  Future<void> command(String action);
  Future<RecordingSettings> recordingSettings();
  Future<void> saveRecordingSettings(RecordingSettings settings);
  Future<void> classify(
    String sessionId,
    String chunkId,
    String classification,
  );
  Future<void> saveNote(String nightId, List<String> tags, String note);
  Future<Map<String, dynamic>> playback(
    String action, {
    String? sessionId,
    String? chunkId,
    int? positionMs,
  });
}

class NativeSleepPlatform implements SleepPlatform {
  static const _channel = MethodChannel('mianban/sleep');

  Future<Map<String, dynamic>> _request(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    dynamic response;
    try {
      response = await _channel.invokeMethod<dynamic>(method, arguments);
    } on MissingPluginException {
      if (method == 'snapshot') {
        return {
          'sessions': <dynamic>[],
          'notes': <String, dynamic>{},
          'error': '当前平台的录音服务尚未接入',
          'version': '0.2.0',
        };
      }
      throw PlatformException(
        code: 'platform_unavailable',
        message: '当前平台的录音服务尚未接入',
      );
    }
    if (response == null) return {};
    final value = response is String ? jsonDecode(response) : response;
    final json = Map<String, dynamic>.from(value as Map);
    if (json['error'] is String &&
        (json['error'] as String).isNotEmpty &&
        !json.containsKey('sessions')) {
      throw PlatformException(
        code: 'sleep_error',
        message: json['error'] as String,
      );
    }
    return json;
  }

  @override
  Future<SleepSnapshot> snapshot() async =>
      SleepSnapshot.fromJson(await _request('snapshot'));

  @override
  Future<SessionDetail> detail(String sessionId) async =>
      SessionDetail.fromJson(
        await _request('detail', {'sessionId': sessionId}),
      );

  @override
  Future<void> command(String action) async {
    await _request(action);
  }

  @override
  Future<RecordingSettings> recordingSettings() async =>
      RecordingSettings.fromJson(await _request('recordingSettings'));

  @override
  Future<void> saveRecordingSettings(RecordingSettings settings) async {
    await _request('saveRecordingSettings', settings.toJson());
  }

  @override
  Future<void> classify(
    String sessionId,
    String chunkId,
    String classification,
  ) async {
    await _request('classify', {
      'sessionId': sessionId,
      'chunkId': chunkId,
      'classification': classification,
    });
  }

  @override
  Future<void> saveNote(String nightId, List<String> tags, String note) async {
    await _request('saveNote', {
      'nightId': nightId,
      'tags': tags,
      'note': note,
    });
  }

  @override
  Future<Map<String, dynamic>> playback(
    String action, {
    String? sessionId,
    String? chunkId,
    int? positionMs,
  }) => _request('playback', {
    'action': action,
    'sessionId': sessionId,
    'chunkId': chunkId,
    'positionMs': positionMs,
  });
}
