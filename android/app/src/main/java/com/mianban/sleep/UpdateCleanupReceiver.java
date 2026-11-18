package com.mianban.sleep;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import java.io.File;

public final class UpdateCleanupReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction())) {
            new File(context.getCacheDir(), "updates/update.apk").delete();
        }
    }
}
