package com.mianban.sleep;

import android.content.Context;
import android.content.Intent;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import org.junit.*;
import org.junit.runner.RunWith;
import org.json.*;
import java.io.File;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class DevicePipelineTest {
    private final Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
    private RecordingPreferences originalPreferences;
    @Before public void useFullRecordingForPipelineAssertions() {
        originalPreferences = new RecordingPreferences(context);
        RecordingPreferences.save(context, "full", true);
    }
    @After public void restoreRecordingPreferences() {
        RecordingPreferences.save(context, originalPreferences.storageMode, originalPreferences.enhanceAudio);
    }
    private Context isolatedContext() {
        File folder = new File(context.getCacheDir(),"pipeline-fixtures");
        folder.mkdirs();
        return new android.content.ContextWrapper(context) { @Override public File getFilesDir(){return folder;} };
    }

    @Test public void foregroundServiceKeepsCapturingAfterActivityFinishes() throws Exception {
        var instrumentation = InstrumentationRegistry.getInstrumentation();
        try (var input = new android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.getUiAutomation().executeShellCommand(
            "pm grant " + context.getPackageName() + " android.permission.RECORD_AUDIO"))) {
            while(input.read()!=-1) {}
        }
        MonitoringService.validationInput = ControlledInput::new;
        MainActivity activity = (MainActivity) instrumentation.startActivitySync(
            new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        try {
            instrumentation.runOnMainSync(() -> activity.startForegroundService(new Intent(activity,MonitoringService.class).setAction("start")));
            await(() -> MonitoringService.active!=null && MonitoringService.active.snapshot()!=null,5000);
            await(() -> MonitoringService.active.snapshot().optLong("frameCount")>=18,30000);
            MonitoringService service=MonitoringService.active;
            long before=service.snapshot().getLong("frameCount");
            instrumentation.runOnMainSync(activity::finish);
            await(() -> service.snapshot().optLong("frameCount")>=before+5,10000);
            String id=service.snapshot().getString("id");
            context.startService(new Intent(context,MonitoringService.class).setAction("pause"));
            await(() -> service.snapshot().optString("status").equals("paused"),5000);
            if (MonitoringService.active!=null) context.startService(new Intent(context,MonitoringService.class).setAction("stop"));
            await(() -> MonitoringService.active==null,10000);
            assertEquals("completed",new SessionStore(context).detail(id).getJSONObject("summary").getString("status"));
        } finally {
            if (MonitoringService.active!=null) context.startService(new Intent(context,MonitoringService.class).setAction("stop"));
            MonitoringService.validationInput=null;
            instrumentation.runOnMainSync(activity::finish);
        }
    }

    @Test public void bundledModelRunsOfflineAndAacIsDecodable() throws Exception {
        try (SnoreClassifier model = new SnoreClassifier(context)) {
            assertEquals(15600,model.frameSamples());
            SnoreClassifier.Prediction p = model.classify(new short[model.frameSamples()]);
            assertTrue(Float.isFinite(p.snore()));
            assertTrue(p.snore()<SnoreClassifier.UNCERTAIN_THRESHOLD);
            short[] tone = new short[model.frameSamples()];
            for (int index = 0; index < tone.length; index++) {
                tone[index] = (short) (Math.sin(index * 2 * Math.PI * 220 / 16000) * 1500);
            }
            SnoreClassifier.Prediction tonePrediction = model.classify(tone);
            // Same deterministic PCM as the desktop LiteRT smoke evaluation.
            assertEquals(0f, tonePrediction.snore(), 0.001f);
            assertEquals(0.01953125f, tonePrediction.music(), 0.004f);
        }
        SessionStore store = new SessionStore(isolatedContext());
        String id = store.newId();
        store.checkpoint(new JSONObject().put("id",id).put("status","completed").put("startAt",1));
        try (AudioChunkWriter writer = new AudioChunkWriter(store.directory(id),"chunk-00001")) {
            short[] pcm = new short[16000];
            for(int i=0;i<pcm.length;i++)pcm[i]=(short)(Math.sin(i*2*Math.PI*220/16000)*1500);
            writer.write(pcm,pcm.length);
        }
        MediaExtractor extractor = new MediaExtractor();
        try {
            extractor.setDataSource(new File(store.directory(id),"chunk-00001.m4a").getAbsolutePath());
            assertEquals(1,extractor.getTrackCount());
            assertEquals("audio/mp4a-latm",extractor.getTrackFormat(0).getString("mime"));
            extractor.selectTrack(0);
            assertTrue(extractor.getSampleTime()>=0);
        } finally {extractor.release();}
    }

    @Test public void clearAudioPresetWritesPlayableAacAtAHigherDataRate() throws Exception {
        SessionStore store = new SessionStore(isolatedContext());
        File folder = store.directory(store.newId());
        assertTrue(folder.mkdirs() || folder.isDirectory());
        short[] pcm = new short[16000];
        java.util.Random noise = new java.util.Random(42);
        for (int i = 0; i < pcm.length; i++) {
            pcm[i] = (short) (Math.sin(i * 2 * Math.PI * 220 / 16000) * 900
                + noise.nextInt(2000) - 1000);
        }
        long previousBytes = 0;
        for (int bitRate : new int[] {24000, 48000}) {
            String name = "encoded-" + bitRate;
            try (AudioChunkWriter writer = new AudioChunkWriter(folder, name, bitRate)) {
                for (int i = 0; i < 8; i++) writer.write(pcm, pcm.length);
            }
            File file = new File(folder, name + ".m4a");
            MediaExtractor extractor = new MediaExtractor();
            try {
                extractor.setDataSource(file.getAbsolutePath());
                MediaFormat format = extractor.getTrackFormat(0);
                assertEquals(MediaFormat.MIMETYPE_AUDIO_AAC, format.getString(MediaFormat.KEY_MIME));
                assertEquals(16000, format.getInteger(MediaFormat.KEY_SAMPLE_RATE));
                assertEquals(1, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT));
                extractor.selectTrack(0);
                assertTrue(extractor.getSampleTime() >= 0);
                assertTrue(file.length() > previousBytes);
                previousBytes = file.length();
            } finally { extractor.release(); }
        }
    }

    @Test public void correctionsPersistAndInterruptedSessionIsRecoverable() throws Exception {
        Context isolated = isolatedContext();
        SessionStore store = new SessionStore(isolated);
        String id = store.newId();
        JSONObject summary = new JSONObject().put("id",id).put("startAt",1).put("updatedAt",2)
            .put("status","recording").put("snoreMs",2000).put("strongMs",1000).put("uncertainMs",500);
        store.checkpoint(summary);
        store.saveChunk(id,new JSONObject().put("id","chunk-00001").put("snoreMs",2000)
            .put("strongMs",1000).put("uncertainMs",500).put("validMs",4000));
        store.classify(id,"chunk-00001","uncertain");
        JSONObject effective = store.detail(id).getJSONObject("summary");
        assertEquals(0,effective.getLong("snoreMs"));
        assertEquals(4000,effective.getLong("uncertainMs"));
        store.classify(id,"chunk-00001","model");
        assertEquals(2000,store.detail(id).getJSONObject("summary").getLong("snoreMs"));
        store.recoverInterruptedSessions();
        assertEquals("interrupted",store.detail(id).getJSONObject("summary").getString("status"));
        store.saveNote("2026-11-01",new JSONArray().put("鼻塞"),"模拟器验证备注");
        assertEquals("模拟器验证备注",new SessionStore(isolated).notes().getJSONObject("2026-11-01").getString("note"));
        try {store.directory("../../bad");fail("path accepted");}catch(IllegalArgumentException expected){}
    }

    @Test public void capturePipelinePausesResumesAndFinishesWithoutHostMicrophone() throws Exception {
        AtomicBoolean done = new AtomicBoolean();
        RecordingEngine engine = new RecordingEngine(context,new SessionStore(context),new RecordingEngine.Listener(){
            public void changed(String status){}
            public void finished(){done.set(true);}
        }, ControlledInput::new,"validation");
        Thread worker = new Thread(engine);
        worker.start();
        try {
            await(() -> engine.snapshot().optLong("frameCount")>=18,30000);
            assertTrue(engine.snapshot().getLong("validMs")>0);
            assertFalse(engine.snapshot().isNull("inputLevel"));
            assertEquals(BuildConfig.CALIBRATION_FRAMES, engine.snapshot().getInt("calibratedFrames"));
            engine.pause();
            await(() -> engine.snapshot().optString("status").equals("paused"),5000);
            long valid = engine.snapshot().getLong("validMs");
            Thread.sleep(800);
            assertEquals(valid,engine.snapshot().getLong("validMs"));
            engine.resume();
            await(() -> engine.snapshot().optLong("validMs")>valid+1500,10000);
        } finally {engine.stop();worker.join(10000);}
        assertTrue(done.get());
        assertEquals("completed",engine.snapshot().getString("status"));
        JSONObject detail = new SessionStore(context).detail(engine.snapshot().getString("id"));
        assertTrue(detail.getJSONArray("chunks").length()>=2);
        assertTrue(detail.getJSONObject("recording").getBoolean("audioAvailable"));
        JSONObject saved = detail.getJSONObject("summary");
        assertEquals(BuildConfig.MODEL_ID, saved.getString("modelId"));
        assertEquals(BuildConfig.MODEL_CONFIG_SHA256, saved.getString("modelConfigSha256"));
        assertEquals(.35, saved.getJSONObject("detectorSettings").getDouble("snoreThreshold"), .000001);
        String chunkId = detail.getJSONArray("chunks").getJSONObject(0).getString("id");
        File chunkFile = new File(new SessionStore(context).directory(saved.getString("id")), chunkId + ".json");
        JSONObject rawChunk = new JSONObject(new String(java.nio.file.Files.readAllBytes(chunkFile.toPath()),
            java.nio.charset.StandardCharsets.UTF_8));
        JSONObject firstFrame = rawChunk.getJSONArray("frames").getJSONObject(0);
        assertTrue(firstFrame.getBoolean("predictionAvailable"));
        assertTrue(firstFrame.has("speechConfidence"));
        assertTrue(firstFrame.has("musicConfidence"));
        assertNull(FrameStatistics.score(engine.snapshot().getLong("validMs"),0,0,0,1));
    }

    interface Condition {boolean satisfied();}
    static void await(Condition condition,long timeout) throws Exception {
        long end=android.os.SystemClock.elapsedRealtime()+timeout;
        while(!condition.satisfied()&&android.os.SystemClock.elapsedRealtime()<end)Thread.sleep(100);
        assertTrue("Timed out waiting for pipeline",condition.satisfied());
    }
    static final class ControlledInput implements PcmInput {
        volatile boolean running;
        long offset;
        public void start(){running=true;}
        public int read(short[] buffer,int start,int length){
            try {Thread.sleep(length*1000L/16000);}catch(InterruptedException ignored){}
            if(!running)return -3;
            for(int i=0;i<length;i++)buffer[start+i]=(short)(Math.sin((offset+i)*2*Math.PI*220/16000)*800);
            offset+=length;return length;
        }
        public void stop(){running=false;}
        public boolean silenced(){return false;}
        public void close(){stop();}
    }
}
