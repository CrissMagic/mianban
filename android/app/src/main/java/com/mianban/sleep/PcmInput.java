package com.mianban.sleep;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioRecordingConfiguration;
import android.media.MediaRecorder;
import android.os.Build;
import java.util.List;

interface PcmInput extends AutoCloseable {
    void start();
    int read(short[] buffer, int offset, int length);
    void stop();
    boolean silenced();
    void close();
}

final class MicrophoneInput implements PcmInput {
    private final AudioRecord recorder;
    private volatile boolean silenced;
    private AudioManager.AudioRecordingCallback callback;

    @SuppressWarnings("MissingPermission")
    MicrophoneInput(Context context) {
        AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        boolean unprocessed = "true".equals(manager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED));
        int minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        if (minimum <= 0) throw new IllegalStateException("麦克风不支持所需录音格式");
        recorder = new AudioRecord.Builder()
            .setAudioSource(unprocessed ? MediaRecorder.AudioSource.UNPROCESSED : MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(new AudioFormat.Builder().setSampleRate(16000)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(Math.max(minimum * 4, 16000 * 2 * 3)).build();
        if (recorder.getState() != AudioRecord.STATE_INITIALIZED) {
            recorder.release();
            throw new IllegalStateException("麦克风初始化失败");
        }
        for (AudioDeviceInfo device : manager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
            if (device.getType() == AudioDeviceInfo.TYPE_BUILTIN_MIC) { recorder.setPreferredDevice(device); break; }
        }
        if (Build.VERSION.SDK_INT >= 29) {
            callback = new AudioManager.AudioRecordingCallback() {
                @Override public void onRecordingConfigChanged(List<AudioRecordingConfiguration> configurations) {
                    for (AudioRecordingConfiguration configuration : configurations) {
                        if (configuration.getClientAudioSessionId() == recorder.getAudioSessionId()) {
                            silenced = configuration.isClientSilenced();
                        }
                    }
                }
            };
            recorder.registerAudioRecordingCallback(context.getMainExecutor(), callback);
        }
    }

    @Override public void start() { recorder.startRecording(); }
    @Override public int read(short[] buffer, int offset, int length) { return recorder.read(buffer, offset, length, AudioRecord.READ_BLOCKING); }
    @Override public boolean silenced() { return silenced; }
    @Override public void stop() { try { recorder.stop(); } catch (IllegalStateException ignored) { } }
    @Override public void close() {
        stop();
        if (Build.VERSION.SDK_INT >= 29 && callback != null) recorder.unregisterAudioRecordingCallback(callback);
        recorder.release();
    }
}
