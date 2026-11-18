package com.mianban.sleep;

import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/** Logical events are rebuilt from raw detections, so corrections never change their IDs. */
final class SessionTimeline {
    private static final long PERIOD_GAP_MS = 3 * 60 * 1000;
    record Event(String id, long start, long end, int segment) {}
    private final JSONObject summary, overrides;
    private final File directory;
    private final List<JSONObject> frames = new ArrayList<>();
    private final List<JSONObject> parts = new ArrayList<>();
    private final List<Event> events = new ArrayList<>();
    private final List<List<Event>> periods = new ArrayList<>();

    SessionTimeline(File directory, JSONObject summary, JSONObject overrides) throws java.io.IOException, org.json.JSONException {
        this.directory = directory;
        this.summary = summary;
        this.overrides = overrides == null ? new JSONObject() : overrides;
        for (File file : files("chunk-[0-9]{5}\\.json")) {
            JSONObject chunk = SessionStore.readJson(file);
            if (chunk == null) continue;
            JSONArray rows = chunk.optJSONArray("frames");
            if (rows != null) for (int i = 0; i < rows.length(); i++) {
                frames.add(new JSONObject(rows.getJSONObject(i).toString()).put("chunkId", chunk.getString("id")));
            }
            if (summary.optInt("recordingSchema") < 2 && new File(directory, chunk.getString("id") + ".m4a").isFile()) {
                long offset = rows != null && rows.length() > 0 ? rows.getJSONObject(0).optLong("offsetMs")
                    : Math.max(0, chunk.optLong("startAt") - summary.optLong("startAt"));
                parts.add(new JSONObject().put("id", chunk.getString("id")).put("offsetMs", offset)
                    .put("durationMs", chunk.optLong("durationMs")));
            }
        }
        if (summary.optInt("recordingSchema") >= 2) for (File file : files("audio-[0-9]{5}\\.json")) {
            JSONObject part = SessionStore.readJson(file);
            if (part != null && new File(directory, part.getString("id") + ".m4a").isFile()) parts.add(part);
        }
        buildEvents();
        for (Event event : events) {
            List<Event> previous = periods.isEmpty() ? null : periods.get(periods.size() - 1);
            Event last = previous == null ? null : previous.get(previous.size() - 1);
            if (last == null || last.segment != event.segment || event.start - last.end > PERIOD_GAP_MS) {
                previous = new ArrayList<>();
                periods.add(previous);
            }
            previous.add(event);
        }
    }

    private File[] files(String pattern) {
        File[] result = directory.listFiles((folder, name) -> name.matches(pattern));
        if (result == null) return new File[0];
        Arrays.sort(result, Comparator.comparing(File::getName));
        return result;
    }

    private void buildEvents() {
        long first = -1, last = 0, segmentStart = 0, segmentEnd = 0;
        int segment = -1;
        for (JSONObject frame : frames) {
            long offset = frame.optLong("offsetMs");
            if (frame.optInt("segment") != segment) {
                if (first >= 0) addEvent(first, last, segmentStart, segmentEnd, segment);
                first = -1;
                segment = frame.optInt("segment");
                segmentStart = offset;
            }
            segmentEnd = offset + frame.optLong("durationMs");
            if (!frame.optString("label").equals("snore")) continue;
            if (first >= 0 && offset - last >= AudioRetention.GAP_MS) {
                addEvent(first, last, segmentStart, segmentEnd, segment);
                first = -1;
            }
            if (first < 0) first = offset;
            last = segmentEnd;
        }
        if (first >= 0) addEvent(first, last, segmentStart, segmentEnd, segment);
    }

    private void addEvent(long first, long last, long segmentStart, long segmentEnd, int segment) {
        events.add(new Event(String.format(java.util.Locale.ROOT, "event-%05d", events.size() + 1),
            Math.max(segmentStart, first - AudioRetention.CONTEXT_MS),
            Math.min(segmentEnd, last + AudioRetention.CONTEXT_MS), segment));
    }

    private Event eventAt(long offset) {
        int low = 0, high = events.size() - 1;
        while (low <= high) {
            int middle = (low + high) >>> 1;
            Event event = events.get(middle);
            if (offset < event.start) high = middle - 1;
            else if (offset >= event.end) low = middle + 1;
            else return event;
        }
        return null;
    }

    String label(JSONObject frame, String chunkId) {
        String original = frame.optString("label");
        if (original.equals("invalid")) return original;
        Event event = eventAt(frame.optLong("offsetMs"));
        String classification = event != null && overrides.has(event.id)
            ? overrides.optString(event.id) : overrides.optString(chunkId, "model");
        return classification.equals("model") ? original : classification;
    }

    void adjustSummary(JSONObject result) throws java.io.IOException, org.json.JSONException {
        long snore = result.optLong("snoreMs"), strong = result.optLong("strongMs"), uncertain = result.optLong("uncertainMs");
        for (JSONObject frame : frames) {
            Event event = eventAt(frame.optLong("offsetMs"));
            if (event == null || !overrides.has(event.id) || frame.optString("label").equals("invalid")) continue;
            String chunk = frame.getString("chunkId");
            String prior = overrides.optString(chunk, "model");
            if (prior.equals("model")) prior = frame.optString("label");
            String next = label(frame, chunk);
            long duration = frame.optLong("durationMs");
            snore += (next.equals("snore") ? duration : 0) - (prior.equals("snore") ? duration : 0);
            strong += (next.equals("snore") && frame.optBoolean("strong") ? duration : 0)
                - (prior.equals("snore") && frame.optBoolean("strong") ? duration : 0);
            uncertain += (next.equals("uncertain") ? duration : 0) - (prior.equals("uncertain") ? duration : 0);
        }
        result.put("snoreMs", Math.max(0, snore)).put("strongMs", Math.max(0, strong)).put("uncertainMs", Math.max(0, uncertain));
    }

    JSONArray eventJson() throws java.io.IOException, org.json.JSONException {
        JSONArray result = new JSONArray();
        java.util.Map<String, Long> snoreTotals = new java.util.HashMap<>();
        for (JSONObject frame : frames) {
            Event event = eventAt(frame.optLong("offsetMs"));
            if (event != null && label(frame, frame.getString("chunkId")).equals("snore")) {
                snoreTotals.merge(event.id, frame.optLong("durationMs"), Long::sum);
            }
        }
        for (Event event : events) {
            long snore = snoreTotals.getOrDefault(event.id, 0L);
            JSONArray audio = ranges(event.start, event.end);
            long saved = 0;
            for (int i = 0; i < audio.length(); i++) saved += audio.getJSONObject(i).optLong("toMs") - audio.getJSONObject(i).optLong("fromMs");
            result.put(new JSONObject().put("id", event.id).put("startAt", summary.optLong("startAt") + event.start)
                .put("durationMs", event.end - event.start).put("snoreMs", snore)
                .put("classification", overrides.optString(event.id, "model"))
                .put("audioAvailable", audio.length() > 0).put("audioComplete", saved >= event.end - event.start - 100));
        }
        return result;
    }

    JSONObject recording() throws java.io.IOException, org.json.JSONException {
        long duration = 0;
        for (JSONObject part : parts) duration += part.optLong("durationMs");
        return new JSONObject().put("id", "recording").put("startAt", summary.optLong("startAt"))
            .put("durationMs", duration).put("audioAvailable", !parts.isEmpty());
    }

    private String periodId(List<Event> period) {
        return "period-" + period.get(0).id.substring(6) + "-" + period.get(period.size() - 1).id.substring(6);
    }

    JSONArray periodJson(JSONArray eventRows) throws java.io.IOException, org.json.JSONException {
        java.util.Map<String, JSONObject> rows = new java.util.HashMap<>();
        for (int i = 0; i < eventRows.length(); i++) {
            JSONObject row = eventRows.getJSONObject(i);
            rows.put(row.getString("id"), row);
        }
        JSONArray result = new JSONArray();
        for (List<Event> period : periods) {
            JSONArray children = new JSONArray();
            long snore = 0, saved = 0;
            boolean complete = true;
            for (Event event : period) {
                JSONObject row = rows.get(event.id);
                children.put(row);
                snore += row.optLong("snoreMs");
                complete &= row.optBoolean("audioComplete");
                JSONArray audio = ranges(event.start, event.end);
                for (int i = 0; i < audio.length(); i++) {
                    JSONObject range = audio.getJSONObject(i);
                    saved += range.optLong("toMs") - range.optLong("fromMs");
                }
            }
            result.put(new JSONObject().put("id", periodId(period))
                .put("startAt", summary.optLong("startAt") + period.get(0).start)
                .put("endAt", summary.optLong("startAt") + period.get(period.size() - 1).end)
                .put("durationMs", saved).put("snoreMs", snore).put("events", children)
                .put("audioAvailable", saved > 0).put("audioComplete", complete));
        }
        return result;
    }

    JSONArray playback(String id) throws java.io.IOException, org.json.JSONException {
        if (id.equals("recording")) return ranges(0, Long.MAX_VALUE);
        for (Event event : events) if (event.id.equals(id)) return ranges(event.start, event.end);
        for (List<Event> period : periods) if (periodId(period).equals(id)) {
            JSONArray audio = new JSONArray();
            for (Event event : period) {
                JSONArray clips = ranges(event.start, event.end);
                for (int i = 0; i < clips.length(); i++) audio.put(clips.getJSONObject(i));
            }
            return audio;
        }
        // Existing callers and old saved references remain usable.
        if (id.matches("chunk-[0-9]{5}")) for (JSONObject part : parts) if (part.getString("id").equals(id)) {
            return new JSONArray().put(new JSONObject().put("file", id).put("fromMs", 0).put("toMs", part.optLong("durationMs")));
        }
        throw new IllegalArgumentException("录音时段不可用");
    }

    boolean hasEvent(String id) { return events.stream().anyMatch(event -> event.id.equals(id)); }

    private JSONArray ranges(long start, long end) throws java.io.IOException, org.json.JSONException {
        JSONArray result = new JSONArray();
        for (JSONObject part : parts) {
            long offset = part.optLong("offsetMs");
            long from = Math.max(start, offset), to = Math.min(end, offset + part.optLong("durationMs"));
            if (to > from) result.put(new JSONObject().put("file", part.getString("id"))
                .put("fromMs", from - offset).put("toMs", to - offset));
        }
        return result;
    }
}
