package com.mianban.sleep;

import org.junit.Test;
import static org.junit.Assert.*;

public class FrameStatisticsTest {
    @Test public void invalidFramesNeverInflateCoverage() {
        FrameStatistics stats = new FrameStatistics();
        stats.add(15600, "invalid", false);
        assertEquals(0, stats.validSamples);
        assertEquals("invalid", FrameStatistics.decision(.99f, 0, 0, true));
    }
    @Test public void strongSnoringIsSubsetAndFramesDoNotOverlap() {
        FrameStatistics stats = new FrameStatistics();
        stats.add(15600, "snore", true);
        stats.add(15600, "snore", false);
        stats.add(15600, "other", true);
        assertEquals(2925, FrameStatistics.milliseconds(stats.validSamples));
        assertEquals(1950, FrameStatistics.milliseconds(stats.snoreSamples));
        assertEquals(975, FrameStatistics.milliseconds(stats.strongSamples));
    }
    @Test public void speechCompetitionAndUncertaintyArePreserved() {
        assertEquals("uncertain", FrameStatistics.decision(.36f, .9f, 0, false));
        assertEquals("uncertain", FrameStatistics.decision(.2f, 0, 0, false));
        assertEquals("snore", FrameStatistics.decision(.5f, .1f, 0, false));
        assertEquals("other", FrameStatistics.decision(.02f, .9f, 0, false));
    }
    @Test public void shortOrMissingAudioCannotProducePerfectScore() {
        assertNull(FrameStatistics.score(60000,0,0,0,1));
        assertNull(FrameStatistics.score(14400000,0,0,0,.79));
        assertEquals(Integer.valueOf(100), FrameStatistics.score(14400000,0,0,0,.8));
    }
    @Test public void uncertaintyCanWithholdOtherwiseEligibleScore() {
        long valid=14400000;
        assertNull(FrameStatistics.score(valid,valid/10,valid/50,valid/10,1));
        assertEquals(Integer.valueOf(79),FrameStatistics.score(valid,valid/10,valid/50,0,1));
    }
}
