package com.mianban.sleep;

import org.json.JSONObject;

/** Physical checkpoints stay short while logical playback spans their boundaries. */
final class AudioArchive implements AudioRetention.Sink {
    private final SessionStore store;
    private final String session;
    private final boolean enhance;
    private final int bitRate;
    private final AudioNormalizer normalizer = new AudioNormalizer();
    private AudioChunkWriter writer;
    private String name;
    private long start, samples;
    private int index, frames;

    AudioArchive(SessionStore store, String session, boolean enhance) {
        this(store, session, enhance, 24000);
    }

    AudioArchive(SessionStore store, String session, boolean enhance, int bitRate) {
        this.store = store;
        this.session = session;
        this.enhance = enhance;
        this.bitRate = bitRate;
    }

    @Override public void write(short[] pcm, long offsetMs) throws Exception {
        if (writer == null) {
            name = String.format(java.util.Locale.ROOT, "audio-%05d", ++index);
            writer = new AudioChunkWriter(store.directory(session), name, bitRate);
            start = offsetMs;
            samples = 0;
            frames = 0;
        }
        writer.write(enhance ? normalizer.process(pcm) : pcm, pcm.length);
        samples += pcm.length;
        if (++frames >= 60) boundary();
    }

    @Override public void boundary() throws Exception {
        if (writer == null) return;
        AudioChunkWriter current = writer;
        writer = null;
        current.close();
        SessionStore.writeJson(new java.io.File(store.directory(session), name + ".json"),
            new JSONObject().put("id", name).put("offsetMs", start)
                .put("durationMs", FrameStatistics.milliseconds(samples)));
    }
}
