package com.mianban.sleep;

import android.content.Context;
import org.tensorflow.lite.Interpreter;
import org.tensorflow.lite.DataType;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Collections;

/** Offline YAMNet. BuildConfig values come from models/assets/models/manifest.json. */
public final class SnoreClassifier implements AutoCloseable {
    public static final int SAMPLE_RATE = BuildConfig.MODEL_SAMPLE_RATE;
    public static final float SNORE_THRESHOLD = BuildConfig.SNORE_THRESHOLD;
    public static final float UNCERTAIN_THRESHOLD = BuildConfig.UNCERTAIN_THRESHOLD;
    public static final float COMPETITION_RATIO = BuildConfig.COMPETITION_RATIO;
    public static final String MODEL_SHA256 = BuildConfig.MODEL_SHA256;
    private final Interpreter interpreter;
    private final ByteBuffer input;
    private final ByteBuffer output;
    private final int frameSamples;
    private final int snoreIndex;
    private final int speechIndex;
    private final int musicIndex;
    private final List<String> labels = new ArrayList<>();

    public record Prediction(float snore, float speech, float music, String topLabel, double rmsDb, double clipping) {}

    public SnoreClassifier(Context context) throws IOException {
        MessageDigest labelDigest = sha256();
        try (var stream = new DigestInputStream(context.getAssets().open(BuildConfig.MODEL_LABELS_PATH), labelDigest);
             var reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) labels.add(line);
        }
        if (!hex(labelDigest.digest()).equals(BuildConfig.MODEL_LABELS_SHA256)
            || labels.size() != BuildConfig.MODEL_LABEL_COUNT) {
            throw new IOException("声音模型标签校验失败");
        }
        snoreIndex = labels.indexOf("Snoring");
        speechIndex = labels.indexOf("Speech");
        musicIndex = labels.indexOf("Music");
        if (snoreIndex < 0 || speechIndex < 0 || musicIndex < 0) throw new IOException("声音模型标签不完整");

        ByteBuffer model;
        try (var descriptor = context.getAssets().openFd(BuildConfig.MODEL_ASSET_PATH);
             var file = new FileInputStream(descriptor.getFileDescriptor())) {
            model = file.getChannel().map(FileChannel.MapMode.READ_ONLY,
                descriptor.getStartOffset(), descriptor.getDeclaredLength());
            MessageDigest modelDigest = sha256();
            modelDigest.update(model.asReadOnlyBuffer());
            if (!hex(modelDigest.digest()).equals(MODEL_SHA256)) {
                throw new IOException("声音模型文件校验失败");
            }
        }
        Interpreter loaded = new Interpreter(model, new Interpreter.Options().setNumThreads(2));
        try {
            frameSamples = loaded.getInputTensor(0).numElements();
            if (loaded.getInputTensor(0).dataType() != DataType.FLOAT32
                || loaded.getOutputTensor(0).dataType() != DataType.FLOAT32
                || frameSamples != BuildConfig.MODEL_FRAME_SAMPLES
                || loaded.getOutputTensor(0).numElements() != labels.size()) {
                throw new IOException("声音模型输入输出规格不匹配");
            }
        } catch (IOException | RuntimeException error) {
            loaded.close();
            throw error;
        }
        interpreter = loaded;
        input = ByteBuffer.allocateDirect(frameSamples * 4).order(ByteOrder.nativeOrder());
        output = ByteBuffer.allocateDirect(labels.size() * 4).order(ByteOrder.nativeOrder());
    }

    public int frameSamples() { return frameSamples; }

    public Prediction classify(short[] samples) {
        if (samples.length != frameSamples) throw new IllegalArgumentException("声音窗长度无效");
        input.rewind();
        double energy = 0;
        int clipped = 0;
        for (short sample : samples) {
            float normalized = sample / 32768f;
            input.putFloat(normalized);
            energy += normalized * normalized;
            if (Math.abs((int) sample) >= 32760) clipped++;
        }
        input.rewind();
        output.rewind();
        interpreter.runForMultipleInputsOutputs(new Object[]{ input }, Collections.singletonMap(0, output));
        output.rewind();
        float[] values = new float[labels.size()];
        int best = 0;
        for (int index = 0; index < values.length; index++) {
            values[index] = output.getFloat();
            if (values[index] > values[best]) best = index;
        }
        double rms = Math.sqrt(energy / frameSamples);
        return new Prediction(values[snoreIndex], values[speechIndex], values[musicIndex], labels.get(best),
            20 * Math.log10(Math.max(1e-8, rms)), clipped / (double) frameSamples);
    }

    private static MessageDigest sha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException("SHA-256 不可用", error);
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            result.append(Character.forDigit((value >>> 4) & 15, 16));
            result.append(Character.forDigit(value & 15, 16));
        }
        return result.toString();
    }

    @Override public void close() { interpreter.close(); }
}
