package com.mianban.sleep;

import java.util.ArrayDeque;
import java.util.Arrays;

/** A bounded PCM buffer retains breathing pauses and context around snoring. */
final class AudioRetention {
    static final long CONTEXT_MS = 2925;
    static final long GAP_MS = 7800;
    interface Sink {
        void write(short[] samples, long offsetMs) throws Exception;
        void boundary() throws Exception;
    }
    private record Frame(short[] samples, long offsetMs) {
        long duration() { return FrameStatistics.milliseconds(samples.length); }
    }
    private final boolean full;
    private final Sink sink;
    private final ArrayDeque<Frame> pending = new ArrayDeque<>();
    private boolean event;
    private long pendingMs;

    AudioRetention(boolean full, Sink sink) { this.full = full; this.sink = sink; }

    void accept(short[] samples, int count, long offsetMs, boolean snore) throws Exception {
        Frame frame = new Frame(Arrays.copyOf(samples, count), offsetMs);
        if (full) { sink.write(frame.samples, offsetMs); return; }
        if (snore) {
            flush(Long.MAX_VALUE);
            event = true;
            sink.write(frame.samples, offsetMs);
            return;
        }
        pending.add(frame);
        pendingMs += frame.duration();
        if (event && pendingMs >= GAP_MS) {
            flush(CONTEXT_MS);
            sink.boundary();
            event = false;
        }
        if (!event) trimContext();
    }

    private void trimContext() {
        while (!pending.isEmpty() && pendingMs - pending.peek().duration() >= CONTEXT_MS) {
            pendingMs -= pending.remove().duration();
        }
    }

    private void flush(long limit) throws Exception {
        long written = 0;
        while (!pending.isEmpty() && written < limit) {
            Frame frame = pending.remove();
            pendingMs -= frame.duration();
            sink.write(frame.samples, frame.offsetMs);
            written += frame.duration();
        }
    }

    void finish() throws Exception {
        if (event) flush(CONTEXT_MS);
        pending.clear();
        pendingMs = 0;
        event = false;
        sink.boundary();
    }
}
