package com.mianban.sleep;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Independent AAC chunks bound crash loss and keep a full night compact. */
final class AudioChunkWriter implements AutoCloseable {
    private final MediaCodec codec;
    private final MediaMuxer muxer;
    private final File pending;
    private final File destination;
    private final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
    private int track = -1;
    private long samples;
    private boolean closed;

    AudioChunkWriter(File directory, String name) throws IOException {
        this(directory, name, 24000);
    }

    AudioChunkWriter(File directory, String name, int bitRate) throws IOException {
        pending = new File(directory, name + ".partial");
        destination = new File(directory, name + ".m4a");
        MediaFormat format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, 16000, 1);
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 32768);
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        muxer = new MediaMuxer(pending.getAbsolutePath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        codec.start();
    }

    void write(short[] pcm, int count) throws IOException {
        int position = 0;
        int attempts = 0;
        while (position < count) {
            int index = codec.dequeueInputBuffer(10000);
            if (index < 0) {
                drain(false);
                if (++attempts > 200) throw new IOException("录音编码超时");
                continue;
            }
            ByteBuffer input = codec.getInputBuffer(index);
            if (input == null) throw new IOException("录音编码缓冲不可用");
            input.clear();
            input.order(ByteOrder.LITTLE_ENDIAN);
            int length = Math.min(count - position, input.remaining() / 2);
            for (int offset = 0; offset < length; offset++) input.putShort(pcm[position + offset]);
            codec.queueInputBuffer(index, 0, length * 2, samples * 1000000L / 16000, 0);
            samples += length;
            position += length;
            attempts = 0;
            drain(false);
        }
    }

    private void drain(boolean ending) throws IOException {
        int attempts = 0;
        while (true) {
            int index = codec.dequeueOutputBuffer(info, ending ? 10000 : 0);
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!ending) return;
                if (++attempts > 200) throw new IOException("录音封装超时");
                continue;
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                track = muxer.addTrack(codec.getOutputFormat());
                muxer.start();
                continue;
            }
            if (index < 0) continue;
            ByteBuffer output = codec.getOutputBuffer(index);
            if (output != null && info.size > 0 && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                if (track < 0) throw new IOException("录音格式尚未就绪");
                output.position(info.offset);
                output.limit(info.offset + info.size);
                muxer.writeSampleData(track, output, info);
            }
            boolean end = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
            codec.releaseOutputBuffer(index, false);
            if (end) return;
        }
    }

    @Override public void close() throws IOException {
        if (closed) return;
        closed = true;
        IOException failure = null;
        try {
            int index = codec.dequeueInputBuffer(2000000);
            if (index < 0) throw new IOException("录音结束缓冲不可用");
            codec.queueInputBuffer(index, 0, 0, samples * 1000000L / 16000, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            drain(true);
            if (track >= 0) muxer.stop();
        } catch (Exception error) {
            failure = new IOException("录音文件未完成", error);
        } finally {
            try { codec.stop(); } catch (Exception ignored) { }
            codec.release();
            muxer.release();
        }
        if (failure != null) throw failure;
        if (!pending.renameTo(destination)) throw new IOException("录音保存失败");
    }
}
