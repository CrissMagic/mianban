# Android 构建、发布与更新

源码和工作流位于 [CrissMagic/mianban](https://github.com/CrissMagic/mianban)，正式 APK 和 SHA-256 校验文件放在同仓库的 [GitHub Releases](https://github.com/CrissMagic/mianban/releases)。

## 两种安装包

| 安装包 | 应用 ID | 签名和升级路径 |
| --- | --- | --- |
| 本地体验包 | `com.mianban.sleep.debug` | 沿用原有调试证书，可覆盖 0.3.3 及同签名的体验包 |
| GitHub 正式包 | `com.mianban.sleep` | 使用专用签名，首次独立安装，此后可通过应用内更新覆盖安装 |

体验包和正式包各自持有私有数据。体验包内现有录音可继续在体验包查看，卸载会清除其录音。正式包的后续更新应一直使用同一个签名证书。[Android 应用签名](https://developer.android.com/studio/publish/app-signing)

## 发布

1. 更新 `pubspec.yaml` 的 `version`，例如 `0.3.5+9`。`+` 后面的 Android 版本号每次递增，Git 标签对应 `v0.3.5`。
2. 在私有仓库的 Actions 里运行 **Android release** 可以先验证并下载签名 APK。推送 `vX.Y.Z` 标签会触发打包和发布。
3. 工作流先检查 Flutter 代码和测试，再校验 APK 包名、版本、签名证书及 SHA-256。公开发行先创建草稿，确认附件和 GitHub 报告的 SHA-256 一致后发布。已发布的相同标签会校验内容；更改已发布版本需要新的版本号和标签。

以下配置位于仓库的 Actions 设置。

| 类型 | 名称 | 用途 |
| --- | --- | --- |
| Variable | `ANDROID_CERT_SHA256` | 正式签名证书的 SHA-256，64 位小写十六进制 |
| Secret | `ANDROID_KEYSTORE_B64` | PKCS#12 签名文件的 Base64，别名 `mianban` |
| Secret | `ANDROID_KEYSTORE_PASSWORD` | PKCS#12 的口令 |

发布任务用内置 `GITHUB_TOKEN` 的 `contents: write` 权限上传发行资源，签名构建任务保持只读仓库权限。手机从公开的 Releases 获取 APK。[GitHub 发行版与附件](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository) · [工作流权限](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions)

## 应用内更新

打开「更多 → 应用更新 → 检查更新」。更高版本会显示下载按钮，下载完成校验 SHA-256。按「安装更新」后，App 核对包名、版本和签名，再打开 Android 安装界面。首次安装需要授权当前 App 作为安装来源。结束并保存监测后即可更新。

更新读取公开仓库的最新正式发行，安装包命名为 `mianban-android-<版本>-<Android版本号>.apk`。草稿与预发行通过 GitHub 最新发行接口过滤。正式包内置下载仓库地址。未指定仓库的普通本地体验包仍可打开更新页查看当前版本。[GitHub 最新发行 API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)

## 本地正式签名

在原 Windows 账户下运行 `pwsh -File tools/build_signed_android.ps1`，输出正式签名 APK 和校验文件。脚本使用 `.signing/android-release.p12` 和本机账户保护的 DPAPI 口令文件，目录由 Git 忽略。备份签名文件及可恢复的口令是后续持续发布的前提，DPAPI 副本依赖原 Windows 账户。
