package com.mianban.sleep;

import android.Manifest;
import android.app.*;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.*;
import java.util.function.Supplier;

public final class MonitoringService extends Service {
    static volatile MonitoringService active;
    // Instrumentation supplies controlled PCM; production always opens AudioRecord.
    static volatile Supplier<PcmInput> validationInput;
    static final String START = "start", PAUSE = "pause", RESUME = "resume", STOP = "stop";
    private static final String CHANNEL = "sleep_monitoring";
    private final Handler main = new Handler(Looper.getMainLooper());
    private PowerManager.WakeLock wakeLock;
    private RecordingEngine engine;

    @Override public void onCreate() {
        super.onCreate();
        getSystemService(NotificationManager.class).createNotificationChannel(
            new NotificationChannel(CHANNEL, "夜间监测", NotificationManager.IMPORTANCE_LOW));
        wakeLock = ((PowerManager) getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MianBan:recording");
        wakeLock.setReferenceCounted(false);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? STOP : intent.getAction();
        if (START.equals(action) && engine == null) {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) { stopSelf(); return START_NOT_STICKY; }
            active = this;
            startForeground(101, notification("calibrating"));
            Supplier<PcmInput> test = BuildConfig.DEBUG ? validationInput : null;
            engine = new RecordingEngine(this, new SessionStore(this), new RecordingEngine.Listener() {
                @Override public void changed(String status) { main.post(() -> update(status)); }
                @Override public void finished() { main.post(() -> { releaseWake(); active = null; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); }); }
            }, test != null ? test : () -> new MicrophoneInput(this), test != null ? "validation" : "microphone");
            acquireWake();
            new Thread(engine, "sleep-capture").start();
        } else if (engine != null) {
            if (PAUSE.equals(action)) engine.pause();
            if (RESUME.equals(action)) { acquireWake(); engine.resume(); }
            if (STOP.equals(action)) engine.stop();
        } else stopSelf();
        return START_NOT_STICKY;
    }

    org.json.JSONObject snapshot() { return engine == null ? null : engine.snapshot(); }
    private void acquireWake() { if (!wakeLock.isHeld()) wakeLock.acquire(12L * 60 * 60 * 1000); }
    private void releaseWake() { if (wakeLock != null && wakeLock.isHeld()) wakeLock.release(); }
    private void update(String status) {
        if (status.equals("paused") || status.equals("stopping") || status.equals("error") || status.equals("completed")) releaseWake();
        else acquireWake();
        getSystemService(NotificationManager.class).notify(101, notification(status));
    }
    private Notification notification(String status) {
        boolean paused = status.equals("paused");
        Intent open = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent content = PendingIntent.getActivity(this, 1, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder builder = new Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now).setContentTitle("眠伴")
            .setContentText(paused ? "监测已暂停" : "正在记录夜间声音")
            .setContentIntent(content).setOngoing(true).setOnlyAlertOnce(true);
        if (paused) {
            Intent resume = new Intent(this, MainActivity.class).putExtra("resume", true).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
            builder.addAction(new Notification.Action.Builder(null, "继续监测", PendingIntent.getActivity(this, 2, resume,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT)).build());
        } else builder.addAction(new Notification.Action.Builder(null, "暂停", serviceIntent(PAUSE, 3)).build());
        builder.addAction(new Notification.Action.Builder(null, "结束", serviceIntent(STOP, 4)).build());
        return builder.build();
    }
    private PendingIntent serviceIntent(String action, int code) {
        return PendingIntent.getService(this, code, new Intent(this, MonitoringService.class).setAction(action), PendingIntent.FLAG_IMMUTABLE);
    }
    @Override public void onDestroy() {
        if (engine != null) engine.stop();
        if (active == this) active = null;
        releaseWake();
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
