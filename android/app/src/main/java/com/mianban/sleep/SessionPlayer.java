package com.mianban.sleep;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.media.audiofx.LoudnessEnhancer;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONArray;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** One seekable track over private AAC files, including trimmed legacy recordings. */
final class SessionPlayer {
    private record Part(File file, int from, int to) { int duration() { return to - from; } }
    private final List<Part> parts = new ArrayList<>();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final boolean enhance;
    private final Runnable boundary = this::checkBoundary;
    private MediaPlayer player;
    private LoudnessEnhancer effect;
    private int index, duration;
    private boolean ended;
    private boolean requestedPlaying;
    private String failure = "";

    SessionPlayer(Context context, File directory, JSONArray ranges, boolean enhance) throws Exception {
        this.enhance = enhance;
        for (int i = 0; i < ranges.length(); i++) {
            var range = ranges.getJSONObject(i);
            String file = range.getString("file");
            if (!file.matches("(chunk|audio)-[0-9]{5}")) throw new IllegalArgumentException("录音路径无效");
            Part part = new Part(new File(directory, file + ".m4a"), range.getInt("fromMs"), range.getInt("toMs"));
            if (part.duration() > 0) { parts.add(part); duration += part.duration(); }
        }
        if (parts.isEmpty()) throw new IllegalArgumentException("录音文件不可用");
        try { open(0); } catch (Exception error) { release(); throw error; }
    }

    private void open(int position) throws Exception {
        closePart();
        Part part = parts.get(index);
        player = new MediaPlayer();
        player.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build());
        player.setDataSource(part.file.getAbsolutePath());
        player.prepare();
        player.setOnCompletionListener(value -> advance());
        player.setOnErrorListener((value, what, extra) -> {
            failure = "录音播放中断，请重新打开此时段";
            requestedPlaying = false;
            closePart();
            return true;
        });
        if (enhance) {
            try {
                effect = new LoudnessEnhancer(player.getAudioSessionId());
                effect.setTargetGain(1800);
                effect.setEnabled(true);
            } catch (RuntimeException unavailable) {
                if (effect != null) { effect.release(); effect = null; }
            }
        }
        player.setOnSeekCompleteListener(value -> { if (requestedPlaying) { value.start(); schedule(); } });
        player.seekTo(part.from + position, MediaPlayer.SEEK_CLOSEST);
    }

    void start() throws Exception {
        requestedPlaying = true;
        if (ended) { ended = false; index = 0; open(0); }
        else if (player != null) { player.start(); schedule(); }
    }
    void pause() { requestedPlaying = false; if (player != null) player.pause(); handler.removeCallbacks(boundary); }
    boolean isPlaying() { return requestedPlaying && !ended && failure.isEmpty(); }
    int getDuration() { return duration; }
    int getCurrentPosition() {
        if (ended) return duration;
        int position = 0;
        for (int i = 0; i < index; i++) position += parts.get(i).duration();
        if (player != null) position += Math.max(0, Math.min(parts.get(index).duration(), player.getCurrentPosition() - parts.get(index).from));
        return position;
    }
    String error() { return failure; }

    void seekTo(int position) throws Exception {
        int local = Math.max(0, Math.min(duration, position));
        index = 0;
        while (index < parts.size() - 1 && local >= parts.get(index).duration()) local -= parts.get(index++).duration();
        ended = false;
        open(local);
    }

    private void schedule() { handler.removeCallbacks(boundary); handler.postDelayed(boundary, 25); }
    private void checkBoundary() {
        if (player == null || !requestedPlaying) return;
        if (!player.isPlaying()) { schedule(); return; }
        if (player.getCurrentPosition() >= parts.get(index).to) advance();
        else schedule();
    }
    private void advance() {
        closePart();
        if (++index >= parts.size()) { index = parts.size() - 1; ended = true; requestedPlaying = false; return; }
        try { open(0); } catch (Exception error) { failure = "部分录音无法播放，请重新打开此时段"; closePart(); }
    }
    private void closePart() {
        handler.removeCallbacks(boundary);
        if (effect != null) { effect.release(); effect = null; }
        if (player != null) { player.release(); player = null; }
    }
    void release() { closePart(); }
}
