package com.mianban.sleep;

/** Sample counts avoid overlap and accumulated duration rounding. */
public final class FrameStatistics {
    public long validSamples;
    public long snoreSamples;
    public long strongSamples;
    public long uncertainSamples;

    public static String decision(float snore, float speech, float music, boolean unusable) {
        if (unusable) return "invalid";
        if (snore >= SnoreClassifier.SNORE_THRESHOLD
            && snore >= Math.max(speech, music) * SnoreClassifier.COMPETITION_RATIO) return "snore";
        if (snore >= SnoreClassifier.UNCERTAIN_THRESHOLD) return "uncertain";
        return "other";
    }

    public void add(int samples, String label, boolean strong) {
        if (samples <= 0 || label.equals("invalid")) return;
        validSamples += samples;
        if (label.equals("snore")) {
            snoreSamples += samples;
            if (strong) strongSamples += samples;
        }
        if (label.equals("uncertain")) uncertainSamples += samples;
    }

    public static long milliseconds(long samples) { return samples * 1000 / 16000; }

    public static Integer score(long validMs, long snoreMs, long strongMs, long uncertainMs, double coverage) {
        if (validMs < 4 * 60 * 60 * 1000L || coverage < 0.8) return null;
        int estimate = (int) Math.round(100 * Math.exp(-2.0 * (snoreMs + strongMs) / validMs));
        int lower = (int) Math.round(100 * Math.exp(-2.0 * (snoreMs + strongMs + 2 * uncertainMs) / validMs));
        return estimate - lower > 5 ? null : estimate;
    }
}
