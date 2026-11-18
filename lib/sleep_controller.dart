import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'domain/sleep_data.dart';
import 'platform/sleep_platform.dart';

String errorMessage(Object error) =>
    error is PlatformException ? error.message ?? '操作失败，请重试' : error.toString();

class SleepController extends ChangeNotifier with WidgetsBindingObserver {
  SleepController(this.platform);

  final SleepPlatform platform;
  SleepSnapshot snapshot = const SleepSnapshot();
  String error = '';
  bool loading = true;
  bool busy = false;
  bool _refreshing = false;
  bool _disposed = false;
  Timer? _timer;

  List<SleepNight> get nights => groupNights(snapshot);
  SleepSession? get active => snapshot.active;

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    await refresh();
    _startPolling();
  }

  void _startPolling() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => refresh(),
    );
  }

  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    try {
      final next = await platform.snapshot();
      if (!_disposed) {
        snapshot = next;
        error = next.error;
      }
    } catch (failure) {
      if (!_disposed) error = errorMessage(failure);
    } finally {
      _refreshing = false;
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> command(String action) async {
    if (busy || _disposed) return;
    busy = true;
    error = '';
    notifyListeners();
    try {
      await platform.command(action);
      await refresh();
    } catch (failure) {
      if (!_disposed) error = errorMessage(failure);
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> saveNote(String nightId, List<String> tags, String note) async {
    await platform.saveNote(nightId, tags, note);
    await refresh();
  }

  void dismissError() {
    error = '';
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
      _startPolling();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class PlaybackController extends ChangeNotifier with WidgetsBindingObserver {
  PlaybackController(this.platform) {
    WidgetsBinding.instance.addObserver(this);
  }

  final SleepPlatform platform;
  String? sessionId;
  String? chunkId;
  double positionMs = 0;
  double durationMs = 0;
  bool playing = false;
  bool busy = false;
  String error = '';
  bool _disposed = false;
  bool _polling = false;
  int _generation = 0;
  Timer? _timer;

  bool matches(String session, String chunk) =>
      sessionId == session && chunkId == chunk;

  void _apply(Map<String, dynamic> value) {
    sessionId = value['sessionId'] as String?;
    chunkId = value['chunkId'] as String?;
    positionMs = (value['positionMs'] as num?)?.toDouble() ?? 0;
    durationMs = (value['durationMs'] as num?)?.toDouble() ?? 0;
    playing = value['playing'] as bool? ?? false;
    _timer?.cancel();
    if (playing) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _poll(),
      );
    }
  }

  Future<void> _poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    final generation = _generation;
    try {
      final value = await platform.playback('state');
      if (!_disposed && generation == _generation) {
        _apply(value);
        notifyListeners();
      }
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = errorMessage(failure);
        playing = false;
        _timer?.cancel();
        notifyListeners();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> toggle(String session, String chunk) async {
    await _action(
      matches(session, chunk) && playing ? 'pause' : 'play',
      session: session,
      chunk: chunk,
    );
  }

  Future<void> seek(double position) =>
      _action('seek', position: position.round());
  Future<void> stop() => _action('stop');

  Future<void> _action(
    String action, {
    String? session,
    String? chunk,
    int? position,
  }) async {
    if (_disposed || busy) return;
    busy = true;
    error = '';
    _generation++;
    _timer?.cancel();
    notifyListeners();
    try {
      final value = await platform.playback(
        action,
        sessionId: session,
        chunkId: chunk,
        positionMs: position,
      );
      if (!_disposed) _apply(value);
    } catch (failure) {
      if (!_disposed) {
        error = errorMessage(failure);
        if (action == 'play') {
          sessionId = session;
          chunkId = chunk;
          positionMs = 0;
          durationMs = 0;
          playing = false;
        }
      }
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(stop());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(
      platform.playback('stop').catchError((Object _) => <String, dynamic>{}),
    );
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
