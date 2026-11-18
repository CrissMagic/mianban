# 眠伴

面向单人睡眠的本地鼾声记录应用。当前应用入口是根目录的 Flutter 工程，今日、趋势、状态、每日明细、比较和评分统一使用 Dart。Android 通过 MethodChannel 调用录音前台服务、YAMNet 和本地音频播放器。

## 工程

| 目录 | 内容 |
| --- | --- |
| `lib/` | Flutter 页面、状态管理、指标及评分、平台接口 |
| `lib/ai/` | 大模型协议适配、加密密钥配置、调用与费用账本 |
| `android/` | Android 权限、录音服务、音频编码、YAMNet、私有存储和播放器 |
| `ios/` | Flutter iOS 宿主，录音与模型平台适配待接入 |
| `models/` | YAMNet 权重、唯一参数配置、许可证及 Python 评测工具 |
| `test/` | Dart 统计与页面回归测试 |
| `integration_test/` | Flutter 正常入口与 Android 平台桥联调测试 |
| `deliverables/` | 本地构建输出，正式安装包见 [GitHub Releases](https://github.com/CrissMagic/mianban/releases) |

Flutter 构建统一打包 `models/assets/models/`。Android 从该目录的 manifest 生成检测参数，并在构建及运行时校验模型和标签。模型反馈、WAV 评测和微调准备见 [模型工程](models/README.md)。

## 构建与运行

使用 Flutter 3.47.9 / Dart 3.13.7、JDK 21、Android SDK 36、Gradle 9.1.0、AGP 9.0.1。Android 最低 API 26。

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d emulator-5556
flutter build apk --release
```

在 `android/local.properties` 填写本机的 `sdk.dir` 与 `flutter.sdk`。本工作区已将 Flutter 放在 `.tools/flutter/`，可用 `./.tools/flutter/bin/flutter.bat` 代替命令中的 `flutter`。本机路径和 SDK 不进入源码版本管理。

Windows 构建按本机路径设置 JDK 和 SDK。Gradle 套接字受限时，将 `jdk.net.unixdomain.tmpdir` 指向可写短目录。

```powershell
$env:JAVA_HOME='C:/path/to/jdk-21'
$env:ANDROID_HOME='C:/path/to/android-sdk'
```

默认本地构建使用调试证书与包名 `com.mianban.sleep.debug`，可覆盖同签名体验包。GitHub 正式发行使用包名 `com.mianban.sleep` 和专用签名。应用更新入口位于 Android 右上角「更多」。[Android 构建、发布与更新](docs/ANDROID_RELEASE.md)

## 录音与回听

右上角的录音设置可选择“全程保存”或“仅保留鼾声”、音质和响度增强。默认全程保存、开启响度增强、使用节省空间档，设置从下一次监测生效。AAC 单声道的节省空间档为 24 kbps，约 11 MB/小时，清晰档为 48 kbps，约 22 MB/小时，另有分析元数据。

鼾声片段按原始识别帧生成，间隔不足7.8秒的鼾声合并，每段前后各保留约2.925秒。界面把片段间隔不超过3分钟的内容归入一张时段卡片，连续回听会依次播放各段保存的音频并跳过片段间隔。展开明细可逐段回听与纠正，原有片段编号继续用于纠正。暂停及麦克风重启会分开时段。播放支持跨文件拖动。“全程录音”和“已保留音频”默认收起，展开后可回听。

仅鼾声模式用有界内存缓冲保存上下文和呼吸间隔，平静时段的音频会丢弃，整晚的原始分析帧和统计仍保留。新音频使用独立 `audio-*.m4a` 和时间索引，`chunk-*.json` 保存分析检查点。旧版分钟录音直接生成时段和播放范围，原文件及已有纠正保留。人工纠正作用于所选时段，并同步影响趋势与评分。

新录音的响度增强仅处理存储副本，自适应增益最高约24 dB并限制峰值。YAMNet、环境基线及较强鼾声判断继续使用原始PCM。历史原始录音回听在开启增强时尝试系统 LoudnessEnhancer，最高18 dB，支持情况因设备而异。远距离真实声音、背景噪声及失真情况仍需要手机试用验证。

## 大模型配置

从页面右上角打开“模型设置”，选择 OpenAI、DeepSeek、GLM、Qwen、MiMo 或自定义接口，填写个人 API Key，获取模型列表并选择型号，再保存使用。自定义支持 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages，提供请求头鉴权和 Anthropic 版本配置。当前每类保存一组配置，自定义接口使用 HTTPS。

API Key 使用系统安全存储，配置及调用记录使用独立 SQLite 账本。每日明细和状态页的“发送统计并分析”会发送日期、鼾声时长、有效分析时长、数据质量、测试数据标记和已有实验评分。每次生成由用户触发。

每个型号可设置人民币或美元的每百万 Token 单价，包含输入、输出、缓存读取及缓存写入。每次调用保存用量、供应商请求编号、请求及返回型号、起止时间、协议、数据指纹、调用状态和当时的单价快照。费用是按实际返回用量与配置单价计算的 Token 项估算，账单以供应商结算为准。缺少完整用量或适用单价时显示“费用待核对”。使用方法和接口差异见 [AI 接口与计费](docs/AI.md)。

## 设备测试

正常入口测试使用独立包名 `com.mianban.sleep.integration`，并传入 `--no-uninstall`。Windows 脚本会先检查包名、安装到专用 x86_64 模拟器并授予录音及通知权限。它会生成一段短录音，并验证暂停、继续、保存、全程回听及备注。备注验证结束后恢复原有备注。原生设备测试另验证跨分钟鼾声时段、两种保存模式、时段纠正和历史录音兼容。

```powershell
./tools/test_android.ps1 -Device emulator-5556
./tools/test_android.ps1 -Device emulator-5556 -Target integration_test/ai_flow_test.dart
cd android
./gradlew.bat -PMIANBAN_INTEGRATION=true :app:testDebugUnitTest :app:connectedDebugAndroidTest
```

Java 设备测试使用受控输入，在独立测试包中注入，验证 YAMNet、AAC、检查点和前台采集。交付 APK 的正常入口使用真实 AudioRecord。测试注入的记录明确标记并排除评分。

本机 `.tools/flutter-maven/` 缓存了经官方存储校验的 Flutter 引擎依赖。存在该目录时 Gradle 优先读取它，其他环境会从官方仓库下载。

## 平台与数据

Android 已接入录音与模型。iOS 已建立 Flutter 宿主并共享 Dart 页面及业务计算，目前没有 iOS 录音、后台音频和模型适配，界面会明确提示。iOS 构建与设备验证需要 macOS / Xcode。

录音保存在应用私有 `files/recordings/{UUID}/`，沿用原来的 JSON 和 AAC 格式。人工纠正及备注单独保存。后台录音由 Android 前台服务运行，Flutter 页面暂停不会结束记录。关闭系统云备份，卸载会清除本地数据。

## 评分与摘要

实验公式为 `round(100 * exp(-2 * (P + H)))`。P 为鼾声占有效分析时长的比例，H 为较强鼾声比例，且 H 是 P 的子集。单晚至少 4 小时有效分析、80% 覆盖率，待定部分造成的评分范围不超过 5 分才计分。最近 7 晚需至少 3 晚达标，按原始时长合并计算。

指标与最近一次有有效分析的非测试夜间记录比较，界面标注实际日期。短记录也可比较原始时长和比例。声音分布展示两行，以每次监测开始后的经过时间对齐，使用相同时间尺度，同一晚多次记录之间的暂停保留空白。单晚AI分析会发送当晚及该对比日期的统计。

记录摘要使用确定性统计规则。AI 分析在独立模块使用所选供应商生成，并记录每次调用。真实声音准确率、阈值校准和整夜耗电仍需试用记录验证，声音采集与鼾声评分的范围见模型工程说明。
