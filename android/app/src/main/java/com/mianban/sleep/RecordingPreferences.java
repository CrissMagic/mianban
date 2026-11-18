package com.mianban.sleep;

import android.content.Context;
import org.json.JSONObject;

final class RecordingPreferences {
    final String storageMode;
    final boolean enhanceAudio;
    final int bitRate;

    RecordingPreferences(Context context) {
        var preferences = context.getSharedPreferences("recording", Context.MODE_PRIVATE);
        var values = preferences.getAll();
        storageMode = values.get("storageMode") instanceof String mode ? mode : "full";
        enhanceAudio = !(values.get("enhanceAudio") instanceof Boolean enabled) || enabled;
        bitRate = Integer.valueOf(48000).equals(values.get("bitRate")) ? 48000 : 24000;
    }

    JSONObject json() throws Exception {
        return new JSONObject().put("storageMode", storageMode).put("enhanceAudio", enhanceAudio)
            .put("audioBitRate", bitRate);
    }

    static void save(Context context, String mode, boolean enhance) {
        save(context, mode, enhance, new RecordingPreferences(context).bitRate);
    }

    static void save(Context context, String mode, boolean enhance, int bitRate) {
        if (!mode.equals("full") && !mode.equals("snore")) throw new IllegalArgumentException("保存模式无效");
        if (bitRate != 24000 && bitRate != 48000) throw new IllegalArgumentException("录音音质无效");
        if (!context.getSharedPreferences("recording", Context.MODE_PRIVATE).edit()
            .putString("storageMode", mode).putBoolean("enhanceAudio", enhance).putInt("bitRate", bitRate).commit()) {
            throw new IllegalStateException("录音设置保存失败");
        }
    }
}
