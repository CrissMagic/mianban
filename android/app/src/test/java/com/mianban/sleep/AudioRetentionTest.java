package com.mianban.sleep;

import org.junit.Test;
import java.util.ArrayList;
import java.util.List;
import static org.junit.Assert.*;

public class AudioRetentionTest {
    static final class Sink implements AudioRetention.Sink {
        final List<Long> offsets = new ArrayList<>();
        int boundaries;
        public void write(short[] samples, long offset) { offsets.add(offset); }
        public void boundary() { boundaries++; }
    }

    @Test public void retainsContextAndMergesBreathingPauses() throws Exception {
        Sink sink = new Sink();
        AudioRetention retention = new AudioRetention(false, sink);
        for (int i = 0; i < 40; i++) retention.accept(new short[15600], 15600, i * 975L, i == 10 || i == 17);
        retention.finish();
        assertEquals(7 * 975L, (long) sink.offsets.get(0));
        assertEquals(20 * 975L, (long) sink.offsets.get(sink.offsets.size() - 1));
        assertEquals(14, sink.offsets.size());
    }

    @Test public void silenceUsesNoAudioAndStopKeepsOnlyShortTail() throws Exception {
        Sink sink = new Sink();
        AudioRetention retention = new AudioRetention(false, sink);
        for (int i = 0; i < 1000; i++) retention.accept(new short[15600], 15600, i * 975L, false);
        assertTrue(sink.offsets.isEmpty());
        retention.accept(new short[15600], 15600, 975000, true);
        retention.accept(new short[15600], 15600, 975975, false);
        retention.finish();
        assertEquals(5, sink.offsets.size());
    }

    @Test public void fullModeRetainsEveryFrameAndPauseSeparatesEvents() throws Exception {
        Sink sink = new Sink();
        AudioRetention retention = new AudioRetention(true, sink);
        for (int i = 0; i < 120; i++) retention.accept(new short[15600], 15600, i * 975L, false);
        retention.finish();
        assertEquals(120, sink.offsets.size());
        assertEquals(1, sink.boundaries);
    }

    @Test public void normalizationRaisesQuietAudioWithoutMutatingDetectionInput() {
        short[] input = new short[15600];
        for (int i = 0; i < input.length; i++) input[i] = (short) (Math.sin(i * .1) * 100);
        short[] original = input.clone();
        AudioNormalizer normalizer = new AudioNormalizer();
        short[] output = normalizer.process(input);
        assertArrayEquals(original, input);
        assertTrue(Math.abs(output[15000]) > Math.abs(input[15000]) * 10);
        input[100] = Short.MIN_VALUE;
        output = normalizer.process(input);
        assertEquals(-32767, output[100]);
        assertArrayEquals(new short[15600], normalizer.process(new short[15600]));
    }
}
