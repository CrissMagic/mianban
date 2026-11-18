package com.mianban.sleep;

/** Gain is applied only to the archived copy. Detection always receives raw PCM. */
final class AudioNormalizer {
    private double gain = 1;

    short[] process(short[] samples) {
        double energy = 0;
        int peak = 0;
        for (short sample : samples) {
            energy += (double) sample * sample;
            peak = Math.max(peak, Math.abs((int) sample));
        }
        double rms = Math.sqrt(energy / Math.max(1, samples.length));
        double target = rms > 10 ? Math.min(16, 2600 / rms) : 1;
        target = Math.max(1, Math.min(target, 29200.0 / Math.max(1, peak)));
        // Reduce gain immediately for transients, raise it smoothly over a frame.
        gain = Math.min(gain, target);
        short[] result = new short[samples.length];
        for (int index = 0; index < samples.length; index++) {
            gain += (target - gain) / 1600;
            result[index] = (short) Math.max(-32767, Math.min(32767, Math.round(samples[index] * gain)));
        }
        return result;
    }
}
