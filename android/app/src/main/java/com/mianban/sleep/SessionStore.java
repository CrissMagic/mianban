package com.mianban.sleep;

import android.content.Context;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

/** Private, atomic checkpoints. Closed audio chunks have independent metadata. */
public final class SessionStore {
    private static final Object FILE_LOCK = new Object();
    private final File root;
    private final File notesFile;

    public SessionStore(Context context) {
        root = new File(context.getFilesDir(), "recordings");
        notesFile = new File(context.getFilesDir(), "night-notes.json");
        if (!root.exists() && !root.mkdirs()) throw new IllegalStateException("无法创建录音目录");
    }

    public File root() { return root; }

    public File directory(String id) {
        if (id == null || !id.matches("[a-f0-9-]{36}")) throw new IllegalArgumentException("记录编号无效");
        return new File(root, id);
    }

    public String newId() { return UUID.randomUUID().toString(); }

    public void checkpoint(JSONObject summary) throws IOException, JSONException {
        File directory = directory(summary.getString("id"));
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("无法创建记录");
        writeJson(new File(directory, "session.json"), summary);
    }

    public void saveChunk(String sessionId, JSONObject chunk) throws IOException, JSONException {
        String id = chunk.getString("id");
        checkChunkId(id);
        writeJson(new File(directory(sessionId), id + ".json"), chunk);
    }

    public JSONArray summaries() throws IOException, JSONException {
        File[] folders = root.listFiles(File::isDirectory);
        if (folders == null) return new JSONArray();
        List<JSONObject> values = new ArrayList<>();
        for (File folder : folders) {
            if (!folder.getName().matches("[a-f0-9-]{36}")) continue;
            JSONObject summary = readJson(new File(folder, "session.json"));
            if (summary != null) values.add(effectiveSummary(summary));
        }
        values.sort((left, right) -> Long.compare(right.optLong("startAt"), left.optLong("startAt")));
        return new JSONArray(values);
    }

    public JSONObject effectiveSummary(JSONObject original) throws IOException, JSONException {
        JSONObject result = new JSONObject(original.toString());
        File directory = directory(result.getString("id"));
        JSONObject overrides = readJson(new File(directory, "overrides.json"));
        if (overrides == null) return result;
        long snore = result.optLong("snoreMs");
        long strong = result.optLong("strongMs");
        long uncertain = result.optLong("uncertainMs");
        for (var keys = overrides.keys(); keys.hasNext();) {
            String id = keys.next();
            if (!id.matches("chunk-[0-9]{5}")) continue;
            JSONObject chunk = readJson(new File(directory, id + ".json"));
            if (chunk == null) continue;
            String classification = overrides.optString(id, "model");
            if (classification.equals("model")) continue;
            snore -= chunk.optLong("snoreMs");
            strong -= chunk.optLong("strongMs");
            uncertain -= chunk.optLong("uncertainMs");
            if (classification.equals("uncertain")) uncertain += chunk.optLong("validMs");
        }
        result.put("snoreMs", Math.max(0, snore));
        result.put("strongMs", Math.max(0, strong));
        result.put("uncertainMs", Math.max(0, uncertain));
        boolean eventOverride = false;
        for (var keys = overrides.keys(); keys.hasNext();) if (keys.next().startsWith("event-")) eventOverride = true;
        if (eventOverride) new SessionTimeline(directory, original, overrides).adjustSummary(result);
        return result;
    }

    public JSONObject detail(String sessionId) throws IOException, JSONException {
        File directory = directory(sessionId);
        JSONObject summary = readJson(new File(directory, "session.json"));
        if (summary == null) throw new IOException("记录不可用");
        JSONObject overrides = readJson(new File(directory, "overrides.json"));
        SessionTimeline timeline = new SessionTimeline(directory, summary, overrides);
        File[] files = directory.listFiles((folder, name) -> name.matches("chunk-[0-9]{5}\\.json"));
        if (files == null) files = new File[0];
        Arrays.sort(files, Comparator.comparing(File::getName));
        JSONArray chunks = new JSONArray();
        JSONArray buckets = new JSONArray();
        for (File file : files) {
            JSONObject chunk = readJson(file);
            if (chunk == null) continue;
            String id = chunk.getString("id");
            String classification = overrides == null ? "model" : overrides.optString(id, "model");
            JSONArray frames = chunk.optJSONArray("frames");
            if (frames != null) {
                for (int index = 0; index < frames.length(); index++) {
                    JSONObject frame = frames.getJSONObject(index);
                    String label = timeline.label(frame, id);
                    int bucketIndex = (int) (frame.optLong("offsetMs") / 60000);
                    while (buckets.length() <= bucketIndex) buckets.put(new JSONObject()
                        .put("offsetMs", buckets.length() * 60000L).put("snoreMs", 0).put("validMs", 0));
                    JSONObject bucket = buckets.getJSONObject(bucketIndex);
                    if (!frame.optString("label").equals("invalid")) {
                        bucket.put("validMs", bucket.optLong("validMs") + frame.optLong("durationMs"));
                    }
                    if (label.equals("snore")) bucket.put("snoreMs", bucket.optLong("snoreMs") + frame.optLong("durationMs"));
                }
            }
            chunk.remove("frames");
            chunk.put("classification", classification);
            chunk.put("audioAvailable", new File(directory, id + ".m4a").isFile());
            chunk.put("audio", "https://appassets.androidplatform.net/recordings/" + sessionId + "/" + id + ".m4a");
            chunks.put(chunk);
        }
        JSONArray events = timeline.eventJson();
        return new JSONObject().put("summary", effectiveSummary(summary)).put("chunks", chunks).put("buckets", buckets)
            .put("events", events).put("periods", timeline.periodJson(events)).put("recording", timeline.recording());
    }

    public JSONArray playbackRanges(String sessionId, String trackId) throws IOException, JSONException {
        File directory = directory(sessionId);
        JSONObject summary = readJson(new File(directory, "session.json"));
        if (summary == null) throw new IOException("记录不可用");
        return new SessionTimeline(directory, summary, null).playback(trackId);
    }

    public void classify(String sessionId, String chunkId, String classification) throws IOException, JSONException {
        if (chunkId == null || !chunkId.matches("(chunk|event)-[0-9]{5}")) throw new IllegalArgumentException("时段编号无效");
        if (!Arrays.asList("model", "other", "uncertain").contains(classification)) throw new IllegalArgumentException("分类无效");
        File directory = directory(sessionId);
        if (chunkId.startsWith("event-")) {
            JSONObject summary = readJson(new File(directory, "session.json"));
            if (summary == null || !new SessionTimeline(directory, summary, null).hasEvent(chunkId)) throw new IOException("该时段尚未完成");
        } else if (!new File(directory, chunkId + ".json").isFile()) throw new IOException("该片段尚未完成");
        synchronized (FILE_LOCK) {
            File file = new File(directory, "overrides.json");
            JSONObject overrides = readJson(file);
            if (overrides == null) overrides = new JSONObject();
            if (classification.equals("model") && chunkId.startsWith("chunk-")) overrides.remove(chunkId);
            else overrides.put(chunkId, classification);
            writeJson(file, overrides);
        }
    }

    public JSONObject notes() throws IOException, JSONException {
        JSONObject notes = readJson(notesFile);
        return notes == null ? new JSONObject() : notes;
    }

    public void saveNote(String nightId, JSONArray tags, String note) throws IOException, JSONException {
        if (!nightId.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")) throw new IllegalArgumentException("日期无效");
        if (tags.length() > 12 || note.length() > 240) throw new IllegalArgumentException("备注过长");
        synchronized (FILE_LOCK) {
            JSONObject notes = notes();
            notes.put(nightId, new JSONObject().put("tags", tags).put("note", note));
            writeJson(notesFile, notes);
        }
    }

    public void recoverInterruptedSessions() throws IOException, JSONException {
        File[] directories = root.listFiles(File::isDirectory);
        if (directories == null) return;
        for (File directory : directories) {
            if (!directory.getName().matches("[a-f0-9-]{36}")) continue;
            JSONObject summary = readJson(new File(directory, "session.json"));
            if (summary == null) continue;
            if (Arrays.asList("starting", "calibrating", "recording", "paused", "recovering", "stopping").contains(summary.optString("status"))) {
                summary.put("status", "interrupted");
                summary.put("endAt", summary.optLong("updatedAt", summary.optLong("startAt")));
                summary.put("stopReason", "上次记录意外中断，已恢复保存的数据");
                checkpoint(summary);
            }
        }
    }

    private static void checkChunkId(String id) {
        if (id == null || !id.matches("chunk-[0-9]{5}")) throw new IllegalArgumentException("片段编号无效");
    }

    static JSONObject readJson(File file) throws IOException, JSONException {
        synchronized (FILE_LOCK) {
            AtomicFile atomic = new AtomicFile(file);
            if (!file.exists() && !new File(file.getPath() + ".bak").exists()) return null;
            try (FileInputStream input = atomic.openRead()) {
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) bytes.write(buffer, 0, count);
                return new JSONObject(bytes.toString("UTF-8"));
            }
        }
    }

    static void writeJson(File file, JSONObject value) throws IOException {
        synchronized (FILE_LOCK) {
            AtomicFile atomic = new AtomicFile(file);
            FileOutputStream output = null;
            try {
                output = atomic.startWrite();
                output.write(value.toString().getBytes(StandardCharsets.UTF_8));
                atomic.finishWrite(output);
            } catch (IOException error) {
                if (output != null) atomic.failWrite(output);
                throw error;
            }
        }
    }
}
