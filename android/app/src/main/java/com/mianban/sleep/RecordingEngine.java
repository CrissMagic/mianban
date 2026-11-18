package com.mianban.sleep;

import android.content.Context;
import android.os.SystemClock;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.IOException;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.function.Supplier;

/** One worker owns capture, inference, encoding, and checkpoints. */
final class RecordingEngine implements Runnable {
    interface Listener { void changed(String status); void finished(); }
    private final Context context;
    private final SessionStore store;
    private final Listener listener;
    private final Supplier<PcmInput> factory;
    private final String source;
    private final String id;
    private final String night;
    private final long startAt = System.currentTimeMillis();
    private final long started = SystemClock.elapsedRealtime();
    private final FrameStatistics totals = new FrameStatistics();
    private final Object pauseLock = new Object();
    private volatile boolean running = true;
    private volatile boolean paused;
    private volatile PcmInput input;
    private String status = "starting";
    private String reason = "";
    private long pausedAt, pausedMs, calibrationMs, frames, inferenceMs;
    private double baseline = BuildConfig.BASELINE_FLOOR_DBFS;
    private double lastLevel = -160;
    private long lastFrameAt;
    private int calibratedFrames;
    private boolean inputUnavailable;
    private float lastConfidence;
    private int chunkIndex, chunkFrames;
    private final RecordingPreferences preferences;
    private final AudioRetention audio;
    private long nextOffsetMs;
    private int segment;
    private JSONObject chunk;
    private JSONArray frameRows;
    private FrameStatistics chunkTotals;
    private long chunkSamples;

    RecordingEngine(Context context, SessionStore store, Listener listener, Supplier<PcmInput> factory, String source) {
        this.context = context;
        this.store = store;
        this.listener = listener;
        this.factory = factory;
        this.source = source;
        id = store.newId();
        preferences = new RecordingPreferences(context);
        audio = new AudioRetention(preferences.storageMode.equals("full"),
            new AudioArchive(store, id, preferences.enhanceAudio, preferences.bitRate));
        LocalDateTime now = LocalDateTime.now();
        night = (now.getHour() < 12 ? now.toLocalDate().minusDays(1) : now.toLocalDate()).toString();
    }

    synchronized JSONObject snapshot() {
        try {
            long elapsed = Math.max(0, SystemClock.elapsedRealtime() - started);
            long pause = pausedMs + (pausedAt == 0 ? 0 : SystemClock.elapsedRealtime() - pausedAt);
            long target = Math.max(0, elapsed - pause - calibrationMs);
            long valid = FrameStatistics.milliseconds(totals.validSamples);
            return new JSONObject().put("id", id).put("nightId", night).put("startAt", startAt)
                .put("updatedAt", System.currentTimeMillis()).put("elapsedMs", elapsed)
                .put("activeMs", elapsed - pause).put("targetMs", target).put("calibrationMs", calibrationMs)
                .put("validMs", valid).put("snoreMs", FrameStatistics.milliseconds(totals.snoreSamples))
                .put("strongMs", FrameStatistics.milliseconds(totals.strongSamples))
                .put("uncertainMs", FrameStatistics.milliseconds(totals.uncertainSamples))
                .put("coverage", target > 0 ? Math.min(1, valid / (double) target) : 0)
                .put("status", status).put("stopReason", reason).put("source", source)
                .put("recordingSchema", 2).put("storageMode", preferences.storageMode)
                .put("audioEnhanced", preferences.enhanceAudio)
                .put("audioBitRate", preferences.bitRate)
                .put("calibratedFrames", calibratedFrames).put("calibrationFrames", BuildConfig.CALIBRATION_FRAMES)
                .put("inputLevel", lastFrameAt == 0 || elapsed - lastFrameAt > 3000 || inputUnavailable
                    ? JSONObject.NULL : lastLevel)
                .put("inputUnavailable", inputUnavailable && elapsed - lastFrameAt <= 3000)
                .put("frameCount", frames).put("inferenceMs", inferenceMs)
                .put("levelDbfs", lastLevel).put("snoreConfidence", lastConfidence)
                .put("baselineDbfs", baseline).put("model", BuildConfig.MODEL_DISPLAY_NAME)
                .put("modelId", BuildConfig.MODEL_ID).put("modelVersion", BuildConfig.MODEL_VERSION)
                .put("modelSha256", SnoreClassifier.MODEL_SHA256)
                .put("modelConfigSha256", BuildConfig.MODEL_CONFIG_SHA256)
                .put("detectorVersion", BuildConfig.DETECTOR_VERSION)
                .put("detectorSettings", new JSONObject(BuildConfig.DETECTOR_SETTINGS_JSON));
        } catch (Exception error) { throw new IllegalStateException(error); }
    }

    private void phase(String value) {
        synchronized (this) { status = value; }
        listener.changed(value);
    }

    void pause() {
        synchronized (this) {
            if (paused || !running) return;
            paused = true;
            pausedAt = SystemClock.elapsedRealtime();
        }
        PcmInput current = input;
        if (current != null) current.stop();
    }

    void resume() {
        synchronized (this) {
            if (!paused || !running) return;
            pausedMs += SystemClock.elapsedRealtime() - pausedAt;
            pausedAt = 0;
            paused = false;
        }
        synchronized (pauseLock) { pauseLock.notifyAll(); }
    }

    void stop() {
        running = false;
        PcmInput current = input;
        if (current != null) current.stop();
        synchronized (pauseLock) { pauseLock.notifyAll(); }
    }

    @Override public void run() {
        boolean failed = false;
        ArrayList<Double> calibration = new ArrayList<>();
        try {
            store.checkpoint(snapshot());
            try (SnoreClassifier model = new SnoreClassifier(context)) {
                short[] buffer = new short[model.frameSamples()];
                int used = 0;
                int failures = 0;
                phase("calibrating");
                while (running) {
                    if (paused) {
                        if (used > 0) { accept(buffer, used, partialLabel(calibration.size() >= BuildConfig.CALIBRATION_FRAMES, buffer, used), false, null); used = 0; }
                        closeChunk();
                        audio.finish();
                        closeInput();
                        phase("paused");
                        store.checkpoint(snapshot());
                        synchronized (pauseLock) { while (paused && running) pauseLock.wait(); }
                        if (!running) break;
                        phase(calibration.size() < BuildConfig.CALIBRATION_FRAMES ? "calibrating" : "recording");
                    }
                    if (input == null) {
                        input = factory.get(); input.start();
                        nextOffsetMs = SystemClock.elapsedRealtime() - started;
                        segment++;
                    }
                    int count = input.read(buffer, used, buffer.length - used);
                    if (count <= 0) {
                        if (paused || !running) continue;
                        closeInput();
                        closeChunk();
                        audio.finish();
                        used = 0;
                        if (++failures > 3) throw new IOException("麦克风读取中断");
                        phase("recovering");
                        Thread.sleep(500);
                        continue;
                    }
                    failures = 0;
                    used += count;
                    if (used != buffer.length) continue;
                    long before = SystemClock.elapsedRealtime();
                    SnoreClassifier.Prediction prediction = model.classify(buffer);
                    boolean zero = true;
                    for (short value : buffer) { if (value != 0) { zero = false; break; } }
                    boolean invalid = zero || input.silenced() || prediction.clipping() > BuildConfig.CLIPPING_THRESHOLD;
                    String label;
                    synchronized (this) {
                        inferenceMs += SystemClock.elapsedRealtime() - before;
                        frames++;
                        lastLevel = prediction.rmsDb();
                        lastFrameAt = SystemClock.elapsedRealtime() - started;
                        inputUnavailable = input.silenced() || zero;
                        lastConfidence = prediction.snore();
                    }
                    if (calibration.size() < BuildConfig.CALIBRATION_FRAMES) {
                        // An unusable microphone cannot establish a misleading quiet baseline.
                        if (!invalid) calibration.add(prediction.rmsDb());
                        synchronized (this) {
                            calibrationMs += FrameStatistics.milliseconds(buffer.length);
                            calibratedFrames = calibration.size();
                        }
                        label = "invalid";
                        if (calibration.size() == BuildConfig.CALIBRATION_FRAMES) {
                            Collections.sort(calibration);
                            synchronized (this) {
                                baseline = Math.max(BuildConfig.BASELINE_FLOOR_DBFS,
                                    calibration.get(BuildConfig.CALIBRATION_FRAMES / 2));
                            }
                            phase("recording");
                        }
                        if (snapshot().optLong("activeMs") > 60000 && calibration.size() < BuildConfig.CALIBRATION_FRAMES)
                            throw new IOException("未收到可用声音，请检查麦克风后重试");
                    } else {
                        label = FrameStatistics.decision(prediction.snore(), prediction.speech(), prediction.music(), invalid);
                        if (!status.equals("recording")) phase("recording");
                    }
                    boolean strong = label.equals("snore")
                        && prediction.rmsDb() >= baseline + BuildConfig.STRONG_GAIN_DB;
                    accept(buffer, used, label, strong, prediction);
                    used = 0;
                    if (frames % 5 == 0) store.checkpoint(snapshot());
                    if (store.root().getUsableSpace() < 64L * 1024 * 1024) throw new IOException("剩余空间不足，记录已保存");
                    if (SystemClock.elapsedRealtime() - started > 12L * 60 * 60 * 1000) {
                        synchronized (this) { reason = "已达到12小时记录上限"; }
                        break;
                    }
                }
                if (used > 0) accept(buffer, used, partialLabel(calibration.size() >= BuildConfig.CALIBRATION_FRAMES, buffer, used), false, null);
            }
        } catch (Exception error) {
            failed = true;
            synchronized (this) { reason = error.getMessage() == null ? "记录中断" : error.getMessage(); }
        } finally {
            running = false;
            phase("stopping");
            closeInput();
            try { closeChunk(); } catch (Exception error) {
                failed = true;
                synchronized (this) { reason = "部分统计未完成保存"; }
            }
            try { audio.finish(); } catch (Exception error) {
                failed = true;
                synchronized (this) { reason = "部分音频未完成，已保留统计和之前的片段"; }
            }
            synchronized (this) {
                if (pausedAt != 0) { pausedMs += SystemClock.elapsedRealtime() - pausedAt; pausedAt = 0; }
            }
            phase(failed ? "error" : "completed");
            try {
                JSONObject finalValue = snapshot().put("endAt", System.currentTimeMillis());
                store.checkpoint(finalValue);
            } catch (Exception error) { android.util.Log.e("MianBan", "Final checkpoint failed", error); }
            listener.finished();
        }
    }

    private void accept(short[] samples, int count, String label, boolean strong,
                        SnoreClassifier.Prediction prediction) throws Exception {
        if (chunk == null) {
            String name = String.format(java.util.Locale.ROOT, "chunk-%05d", ++chunkIndex);
            frameRows = new JSONArray();
            chunkTotals = new FrameStatistics();
            chunkSamples = 0;
            chunkFrames = 0;
            chunk = new JSONObject().put("id", name).put("startAt", startAt + nextOffsetMs);
        }
        long duration = FrameStatistics.milliseconds(count);
        JSONObject frame = new JSONObject()
            .put("offsetMs", nextOffsetMs).put("segment", segment)
            .put("durationMs", duration).put("label", label).put("strong", strong)
            .put("predictionAvailable", prediction != null);
        if (prediction != null) {
            frame.put("confidence", prediction.snore()).put("speechConfidence", prediction.speech())
                .put("musicConfidence", prediction.music()).put("topLabel", prediction.topLabel())
                .put("levelDbfs", prediction.rmsDb()).put("clipping", prediction.clipping());
        }
        frameRows.put(frame);
        synchronized (this) { totals.add(count, label, strong); }
        chunkTotals.add(count, label, strong);
        chunkSamples += count;
        audio.accept(samples, count, nextOffsetMs, label.equals("snore"));
        nextOffsetMs += duration;
        if (++chunkFrames >= 60) closeChunk();
    }

    private void closeChunk() throws Exception {
        if (chunk == null) return;
        chunk.put("durationMs", FrameStatistics.milliseconds(chunkSamples)).put("frames", frameRows)
            .put("validMs", FrameStatistics.milliseconds(chunkTotals.validSamples))
            .put("snoreMs", FrameStatistics.milliseconds(chunkTotals.snoreSamples))
            .put("strongMs", FrameStatistics.milliseconds(chunkTotals.strongSamples))
            .put("uncertainMs", FrameStatistics.milliseconds(chunkTotals.uncertainSamples))
            .put("audioComplete", true);
        store.saveChunk(id, chunk);
        chunk = null;
        store.checkpoint(snapshot());
    }

    private void closeInput() {
        PcmInput current = input;
        input = null;
        if (current != null) current.close();
    }

    private String partialLabel(boolean calibrated, short[] buffer, int count) {
        if (!calibrated || input == null || input.silenced()) return "invalid";
        for (int index = 0; index < count; index++) if (buffer[index] != 0) return "uncertain";
        return "invalid";
    }
}
