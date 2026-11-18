package com.mianban.sleep;

import android.content.Context;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.File;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class EventRecordingTest {
    private final Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();

    private SessionStore store() {
        return new SessionStore(new android.content.ContextWrapper(context) {
            @Override public File getFilesDir() {
                File folder = new File(context.getCacheDir(), "event-fixtures");
                folder.mkdirs();
                return folder;
            }
        });
    }

    private String fixture(SessionStore store, boolean full, boolean legacy) throws Exception {
        String id = store.newId();
        JSONObject summary = new JSONObject().put("id", id).put("startAt", 1000000).put("status", "completed")
            .put("recordingSchema", legacy ? 1 : 2).put("storageMode", full ? "full" : "snore")
            .put("validMs", 180 * 975L).put("snoreMs", 77 * 975L).put("strongMs", 0).put("uncertainMs", 0);
        store.checkpoint(summary);
        AudioRetention retention = new AudioRetention(full, new AudioArchive(store, id, true));
        short[] tone = new short[15600];
        for (int i = 0; i < tone.length; i++) tone[i] = (short) (Math.sin(i * .1) * 100);
        for (int chunk = 0; chunk < 3; chunk++) {
            JSONArray frames = new JSONArray();
            long snore = 0;
            AudioChunkWriter legacyWriter = legacy ? new AudioChunkWriter(store.directory(id), String.format(java.util.Locale.ROOT, "chunk-%05d", chunk + 1)) : null;
            for (int j = 0; j < 60; j++) {
                int i = chunk * 60 + j;
                boolean detected = (i >= 20 && i <= 90) || (i >= 130 && i <= 135);
                if (detected) snore += 975;
                frames.put(new JSONObject().put("offsetMs", i * 975L).put("durationMs", 975)
                    .put("label", detected ? "snore" : "other").put("segment", 1));
                if (legacy) legacyWriter.write(tone, tone.length);
                else retention.accept(tone, tone.length, i * 975L, detected);
            }
            if (legacyWriter != null) legacyWriter.close();
            store.saveChunk(id, new JSONObject().put("id", String.format(java.util.Locale.ROOT, "chunk-%05d", chunk + 1))
                .put("frames", frames).put("durationMs", 58500).put("validMs", 58500).put("snoreMs", snore));
        }
        if (!legacy) retention.finish();
        return id;
    }

    @Test public void modesKeepIdenticalStatisticsAndLongEventsCrossFileBoundaries() throws Exception {
        SessionStore store = store();
        String full = fixture(store, true, false), snore = fixture(store, false, false);
        JSONObject fullDetail = store.detail(full), snoreDetail = store.detail(snore);
        assertEquals(fullDetail.getJSONObject("summary").getLong("validMs"), snoreDetail.getJSONObject("summary").getLong("validMs"));
        assertEquals(2, fullDetail.getJSONArray("events").length());
        assertEquals(fullDetail.getJSONArray("events").toString(), snoreDetail.getJSONArray("events").toString());
        assertTrue(fullDetail.getJSONArray("events").getJSONObject(0).getLong("durationMs") > 60000);
        assertTrue(store.playbackRanges(snore, "event-00001").length() >= 2);
        assertEquals(180 * 975L, fullDetail.getJSONObject("recording").getLong("durationMs"));
        assertTrue(snoreDetail.getJSONObject("recording").getLong("durationMs") < 100000);
        JSONArray periods = snoreDetail.getJSONArray("periods");
        assertEquals(1, periods.length());
        assertEquals(2, periods.getJSONObject(0).getJSONArray("events").length());
        assertEquals(89 * 975L, periods.getJSONObject(0).getLong("durationMs"));
        assertEquals(77 * 975L, periods.getJSONObject(0).getLong("snoreMs"));
        assertEquals(periods.toString(), fullDetail.getJSONArray("periods").toString());
        store.classify(snore, "event-00001", "other");
        assertEquals(6 * 975L, store.detail(snore).getJSONObject("summary").getLong("snoreMs"));
        store.classify(snore, "event-00001", "model");
        assertEquals(77 * 975L, store.detail(snore).getJSONObject("summary").getLong("snoreMs"));
    }

    @Test public void legacyAudioBecomesEventsAndPlaylistSeeksAcrossParts() throws Exception {
        SessionStore store = store();
        String id = fixture(store, true, true);
        assertEquals(2, store.detail(id).getJSONArray("events").length());
        store.classify(id, "chunk-00001", "other");
        assertEquals(37 * 975L, store.detail(id).getJSONObject("summary").getLong("snoreMs"));
        store.classify(id, "event-00001", "model");
        assertEquals(77 * 975L, store.detail(id).getJSONObject("summary").getLong("snoreMs"));
        JSONArray ranges = store.playbackRanges(id, "period-00001-00002");
        AtomicReference<SessionPlayer> reference = new AtomicReference<>();
        AtomicReference<Exception> failure = new AtomicReference<>();
        int firstBoundary = ranges.getJSONObject(0).getInt("toMs") - ranges.getJSONObject(0).getInt("fromMs");
        var instrumentation = InstrumentationRegistry.getInstrumentation();
        instrumentation.runOnMainSync(() -> {
            try {
                SessionPlayer player = new SessionPlayer(context, store.directory(id), ranges, false);
                reference.set(player);
                player.start();
                player.seekTo(firstBoundary - 250);
            } catch (Exception error) { failure.set(error); }
        });
        assertNull(failure.get());
        try {
            DevicePipelineTest.await(() -> reference.get().getCurrentPosition() > firstBoundary + 250, 5000);
            assertTrue(reference.get().isPlaying());
            instrumentation.runOnMainSync(() -> {
                try {
                    reference.get().pause();
                    reference.get().seekTo(reference.get().getDuration() - 1000);
                    assertFalse(reference.get().isPlaying());
                    reference.get().start();
                } catch (Exception error) { failure.set(error); }
            });
            assertNull(failure.get());
            DevicePipelineTest.await(() -> !reference.get().isPlaying(), 5000);
            assertEquals(reference.get().getDuration(), reference.get().getCurrentPosition());
            assertEquals("", reference.get().error());
        } finally { instrumentation.runOnMainSync(() -> reference.get().release()); }
    }

    @Test public void preferencesPersistAndApplyOnlyToNewSessions() throws Exception {
        RecordingPreferences original = new RecordingPreferences(context);
        try {
            RecordingPreferences.save(context, "full", true, 48000);
            RecordingEngine engine = new RecordingEngine(context, store(), new RecordingEngine.Listener() {
                public void changed(String value) {}
                public void finished() {}
            }, DevicePipelineTest.ControlledInput::new, "validation");
            RecordingPreferences.save(context, "snore", false, 24000);
            assertEquals("snore", new RecordingPreferences(context).storageMode);
            assertFalse(new RecordingPreferences(context).enhanceAudio);
            assertEquals(24000, new RecordingPreferences(context).bitRate);
            assertEquals("full", engine.snapshot().getString("storageMode"));
            assertTrue(engine.snapshot().getBoolean("audioEnhanced"));
            assertEquals(48000, engine.snapshot().getInt("audioBitRate"));
        } finally { RecordingPreferences.save(context, original.storageMode, original.enhanceAudio, original.bitRate); }
    }

    @Test public void periodsSeparateLongGapsAndCapturePausesWithoutChangingEventCorrections() throws Exception {
        SessionStore store = store();
        String id = store.newId();
        store.checkpoint(new JSONObject().put("id", id).put("startAt", 1000000).put("snoreMs", 3900));
        JSONArray frames = new JSONArray();
        long[] offsets = {10000, 160000, 350000, 360000};
        for (int i = 0; i < offsets.length; i++) frames.put(new JSONObject().put("offsetMs", offsets[i])
            .put("durationMs", 975).put("label", "snore").put("segment", i == 3 ? 2 : 1));
        store.saveChunk(id, new JSONObject().put("id", "chunk-00001").put("frames", frames).put("snoreMs", 3900));
        JSONArray periods = store.detail(id).getJSONArray("periods");
        assertEquals(3, periods.length());
        assertEquals(2, periods.getJSONObject(0).getJSONArray("events").length());
        String firstId = periods.getJSONObject(0).getString("id");
        store.classify(id, "event-00001", "other");
        assertEquals(firstId, store.detail(id).getJSONArray("periods").getJSONObject(0).getString("id"));
        assertEquals(2925, store.detail(id).getJSONObject("summary").getLong("snoreMs"));
        assertEquals(4, store.detail(id).getJSONArray("events").length());
    }
}
