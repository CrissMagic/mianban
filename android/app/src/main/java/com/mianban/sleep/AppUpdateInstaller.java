package com.mianban.sleep;

import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.util.Arrays;
import java.util.HashSet;
import java.util.HashMap;
import java.util.concurrent.Executor;

final class AppUpdateInstaller {
    private final MainActivity activity;
    private final Executor worker;
    private final File apk;

    AppUpdateInstaller(MainActivity activity, Executor worker) {
        this.activity = activity;
        this.worker = worker;
        apk = new File(new File(activity.getCacheDir(), "updates"), "update.apk");
    }

    void handle(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "info" -> {
                var info = new HashMap<String, Object>();
                info.put("versionName", BuildConfig.VERSION_NAME);
                info.put("versionCode", BuildConfig.VERSION_CODE);
                info.put("apkPath", apk.getAbsolutePath());
                result.success(info);
            }
            case "install" -> {
                Integer code = call.argument("versionCode");
                String version = call.argument("versionName");
                if (code == null || version == null) {
                    result.error("update_failed", "缺少安装包版本信息", null);
                    return;
                }
                worker.execute(() -> {
                    try {
                        verifyArchive(activity.getPackageManager(), activity.getPackageName(), apk, version, code);
                        activity.runOnUiThread(() -> openInstaller(result));
                    } catch (Exception error) {
                        activity.runOnUiThread(() -> result.error("update_failed", error.getMessage(), null));
                    }
                });
            }
            default -> result.notImplemented();
        }
    }

    @SuppressWarnings("deprecation")
    static void verifyArchive(PackageManager manager, String packageName, File apk, String version, int versionCode)
        throws PackageManager.NameNotFoundException {
        if (!apk.isFile()) throw new IllegalStateException("安装包已清理，请重新下载");
        int flags = Build.VERSION.SDK_INT >= 28 ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES;
        PackageInfo archive = manager.getPackageArchiveInfo(apk.getAbsolutePath(), flags);
        if (archive == null || !packageName.equals(archive.packageName)) {
            throw new IllegalArgumentException("安装包与当前应用不匹配");
        }
        PackageInfo installed = manager.getPackageInfo(packageName, flags);
        if (!version.equals(archive.versionName) || codeOf(archive) != versionCode || codeOf(archive) <= codeOf(installed)) {
            throw new IllegalArgumentException("安装包版本与更新信息不符");
        }
        Signature[] original = signersOf(installed);
        Signature[] candidate = signersOf(archive);
        if (original.length == 0 || candidate.length == 0 ||
            !new HashSet<>(Arrays.asList(original)).equals(new HashSet<>(Arrays.asList(candidate)))) {
            throw new IllegalArgumentException("更新签名与当前应用不一致");
        }
    }

    @SuppressWarnings("deprecation")
    private static long codeOf(PackageInfo info) {
        return Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
    }

    @SuppressWarnings("deprecation")
    private static Signature[] signersOf(PackageInfo info) {
        if (Build.VERSION.SDK_INT >= 28) {
            return info.signingInfo == null ? new Signature[0] : info.signingInfo.getApkContentsSigners();
        }
        return info.signatures == null ? new Signature[0] : info.signatures;
    }

    private void openInstaller(MethodChannel.Result result) {
        try {
            if (!activity.visibleForUpdate()) {
                throw new IllegalStateException("请打开应用后安装更新");
            }
            if (MonitoringService.active != null) throw new IllegalStateException("结束并保存监测后可安装更新");
            if (!activity.getPackageManager().canRequestPackageInstalls()) {
                activity.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.fromParts("package", activity.getPackageName(), null)));
                result.success("permission");
                return;
            }
            Uri content = FileProvider.getUriForFile(activity, activity.getPackageName() + ".updates", apk);
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(content, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            activity.startActivity(intent);
            result.success("installer");
        } catch (Exception error) {
            result.error("update_failed", error.getMessage(), null);
        }
    }
}
