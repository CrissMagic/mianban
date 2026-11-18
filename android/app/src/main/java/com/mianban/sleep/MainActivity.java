package com.mianban.sleep;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.util.ArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Flutter's platform bridge owns permissions and playback. Capture lives in the service. */
public final class MainActivity extends FlutterActivity {
    private final ExecutorService storageWorker = Executors.newSingleThreadExecutor();
    private SessionStore store;
    private MethodChannel channel;
    private MethodChannel updateChannel;
    private volatile boolean visible;
    private volatile boolean destroyed;
    private volatile String error = "";
    private MethodChannel.Result pendingStart;
    private boolean startAfterPermission;
    private boolean resumePending;
    private SessionPlayer player;
    private String playingSession;
    private String playingChunk;
    private AudioFocusRequest audioFocus;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        store = new SessionStore(this);
        try {
            if (MonitoringService.active == null) store.recoverInterruptedSessions();
        } catch (Exception failure) { error = "部分历史记录读取失败"; }
        resumePending = getIntent().getBooleanExtra("resume", false);
    }

    @Override public void configureFlutterEngine(FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "mianban/sleep");
        channel.setMethodCallHandler(this::handleCall);
        updateChannel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "mianban/update");
        updateChannel.setMethodCallHandler(new AppUpdateInstaller(this, storageWorker)::handle);
    }

    private void handleCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "snapshot" -> read(result, () -> {
                MonitoringService service = MonitoringService.active;
                JSONObject active = service == null ? null : service.snapshot();
                if (active != null) active = store.effectiveSummary(active);
                return new JSONObject().put("sessions", store.summaries())
                    .put("active", active == null ? JSONObject.NULL : active).put("notes", store.notes())
                    .put("error", error).put("version", BuildConfig.VERSION_NAME)
                    .put("microphoneGranted", checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED);
            });
            case "detail" -> read(result, () -> store.detail(required(call, "sessionId")));
            case "recordingSettings" -> read(result, () -> new RecordingPreferences(this).json());
            case "saveRecordingSettings" -> read(result, () -> {
                int bitRate = call.argument("audioBitRate") instanceof Integer rate
                    ? rate : new RecordingPreferences(this).bitRate;
                RecordingPreferences.save(this, required(call, "storageMode"), Boolean.TRUE.equals(call.argument("enhanceAudio")), bitRate);
                return new RecordingPreferences(this).json();
            });
            case "classify" -> read(result, () -> {
                store.classify(required(call, "sessionId"), required(call, "chunkId"), required(call, "classification"));
                return new JSONObject().put("ok", true);
            });
            case "saveNote" -> read(result, () -> {
                Object tags = call.argument("tags");
                if (!(tags instanceof java.util.List<?>)) throw new IllegalArgumentException("标签格式无效");
                store.saveNote(required(call, "nightId"), new JSONArray((java.util.List<?>) tags), required(call, "note"));
                return new JSONObject().put("ok", true);
            });
            case "start", "pause", "resume", "stop" -> command(call.method, result);
            case "playback" -> handlePlayback(call, result);
            default -> result.notImplemented();
        }
    }

    private static String required(MethodCall call, String name) {
        Object value = call.argument(name);
        if (!(value instanceof String)) throw new IllegalArgumentException("参数无效 " + name);
        return (String) value;
    }

    interface JsonOperation { JSONObject run() throws Exception; }
    private void read(MethodChannel.Result result, JsonOperation operation) {
        storageWorker.execute(() -> {
            try {
                String value = operation.run().toString();
                runOnUiThread(() -> { if (!destroyed) result.success(value); });
            } catch (Exception failure) {
                runOnUiThread(() -> { if (!destroyed) result.error("storage_failed", message(failure), null); });
            }
        });
    }

    private void command(String action, MethodChannel.Result result) {
        try {
            if ((action.equals("start") || action.equals("resume")) && !visible) {
                throw new IllegalStateException("请打开应用后开始监测");
            }
            if (action.equals("start")) {
                if (pendingStart != null) throw new IllegalStateException("正在等待录音授权");
                if (MonitoringService.active != null) { if (result != null) result.success(null); return; }
                ArrayList<String> permissions = new ArrayList<>();
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.RECORD_AUDIO);
                if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.POST_NOTIFICATIONS);
                if (!permissions.isEmpty()) {
                    pendingStart = result;
                    requestPermissions(permissions.toArray(new String[0]), 20);
                    return;
                }
            }
            if (action.equals("start") || action.equals("resume")) stopPlayback();
            Intent intent = new Intent(this, MonitoringService.class).setAction(action);
            if (action.equals("start")) startForegroundService(intent);
            else if (MonitoringService.active != null) startService(intent);
            error = "";
            if (result != null) result.success(null);
        } catch (Exception failure) {
            error = message(failure);
            if (result != null) result.error("monitoring_failed", error, null);
        }
    }

    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code != 20 || pendingStart == null) return;
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            if (visible) finishPermissionStart();
            else startAfterPermission = true;
        } else {
            error = "需要麦克风权限才能监测鼾声";
            pendingStart.error("permission_denied", error, null);
            pendingStart = null;
        }
    }

    private void finishPermissionStart() {
        MethodChannel.Result result = pendingStart;
        pendingStart = null;
        startAfterPermission = false;
        command("start", result);
    }

    @Override protected void onResume() {
        super.onResume();
        visible = true;
        if (startAfterPermission) finishPermissionStart();
        if (resumePending) { resumePending = false; command("resume", null); }
    }

    @Override protected void onPause() {
        visible = false;
        stopPlayback();
        super.onPause();
    }

    boolean visibleForUpdate() { return visible && !isFinishing() && !destroyed; }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        resumePending = intent.getBooleanExtra("resume", false);
    }

    private void handlePlayback(MethodCall call, MethodChannel.Result result) {
        if (!"play".equals(call.argument("action"))) {
            completePlayback(call, result, null, false);
            return;
        }
        storageWorker.execute(() -> {
            try {
                String session = required(call, "sessionId");
                JSONArray ranges = store.playbackRanges(session, required(call, "chunkId"));
                JSONObject summary = SessionStore.readJson(new File(store.directory(session), "session.json"));
                boolean enhance = new RecordingPreferences(this).enhanceAudio && !summary.optBoolean("audioEnhanced");
                runOnUiThread(() -> completePlayback(call, result, ranges, enhance));
            } catch (Exception failure) {
                runOnUiThread(() -> { if (!destroyed) result.error("playback_failed", message(failure), null); });
            }
        });
    }

    private void completePlayback(MethodCall call, MethodChannel.Result result, JSONArray ranges, boolean enhance) {
        if (destroyed) return;
        try { result.success(playback(call, ranges, enhance).toString()); }
        catch (Exception failure) { result.error("playback_failed", message(failure), null); }
    }

    private JSONObject playback(MethodCall call, JSONArray ranges, boolean enhance) throws Exception {
        String action = required(call, "action");
        if (action.equals("play")) {
            if (!visible) throw new IllegalStateException("请打开应用后回听");
            MonitoringService service = MonitoringService.active;
            if (service != null && service.snapshot() != null && !service.snapshot().optString("status").equals("paused")) {
                throw new IllegalStateException("暂停监测后可回听");
            }
            String session = required(call, "sessionId");
            String chunk = required(call, "chunkId");
            if (!chunk.matches("(chunk|event)-[0-9]{5}|period-[0-9]{5}-[0-9]{5}|recording")) throw new IllegalArgumentException("时段编号无效");
            if (player == null || !player.error().isEmpty() || !session.equals(playingSession) || !chunk.equals(playingChunk)) {
                stopPlayback();
                AudioManager audio = getSystemService(AudioManager.class);
                audioFocus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setOnAudioFocusChangeListener(focus -> {
                        if (focus < 0 && player != null && player.isPlaying()) player.pause();
                    }, new Handler(Looper.getMainLooper())).build();
                if (audio.requestAudioFocus(audioFocus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    stopPlayback();
                    throw new IllegalStateException("暂时无法播放录音");
                }
                try {
                    player = new SessionPlayer(this, store.directory(session), ranges, enhance);
                    playingSession = session;
                    playingChunk = chunk;
                } catch (Exception failure) { stopPlayback(); throw failure; }
            }
            if (player.getCurrentPosition() >= player.getDuration()) player.seekTo(0);
            player.start();
        } else if (action.equals("pause")) {
            if (player != null && player.isPlaying()) player.pause();
        } else if (action.equals("seek")) {
            Number position = call.argument("positionMs");
            if (player != null && position != null) player.seekTo(Math.max(0, Math.min(player.getDuration(), position.intValue())));
        } else if (action.equals("stop")) {
            stopPlayback();
        } else if (!action.equals("state")) throw new IllegalArgumentException("播放动作无效");
        if (player != null && !player.error().isEmpty()) throw new IllegalStateException(player.error());
        return new JSONObject().put("sessionId", playingSession == null ? JSONObject.NULL : playingSession)
            .put("chunkId", playingChunk == null ? JSONObject.NULL : playingChunk)
            .put("positionMs", player == null ? 0 : player.getCurrentPosition())
            .put("durationMs", player == null ? 0 : player.getDuration())
            .put("playing", player != null && player.isPlaying());
    }

    private void stopPlayback() {
        if (player != null) { player.release(); player = null; }
        if (audioFocus != null) { getSystemService(AudioManager.class).abandonAudioFocusRequest(audioFocus); audioFocus = null; }
        playingSession = null;
        playingChunk = null;
    }

    @Override protected void onDestroy() {
        destroyed = true;
        if (pendingStart != null) { pendingStart.error("activity_closed", "请重新开始监测", null); pendingStart = null; }
        if (channel != null) channel.setMethodCallHandler(null);
        if (updateChannel != null) updateChannel.setMethodCallHandler(null);
        storageWorker.shutdown();
        stopPlayback();
        super.onDestroy();
    }

    private static String message(Exception failure) {
        return failure.getMessage() == null ? "操作失败，请重试" : failure.getMessage();
    }
}
