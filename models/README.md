# YAMNet 模型工程

当前基线使用官方 YAMNet 预训练权重和 alpha-1 检测参数。模型权重、标签、来源、许可证、参数和评测工具都随本工程保存。Android 和桌面评测读取同一份模型及参数配置。

## 文件

| 路径 | 内容 |
| --- | --- |
| `assets/models/yamnet.tflite` | 官方 float32 权重 |
| `assets/models/labels.txt` | 521 类声音标签 |
| `assets/models/manifest.json` | 模型版本、SHA-256、输入规格和判断参数的唯一配置入口 |
| `assets/models/LICENSE`、`NOTICE.txt` | 许可证和上游来源 |
| `evaluate.py` | 本地 WAV 逐窗推理、时间标注评测和 CSV / JSON 报告 |
| `dataset.example.json` | 本人录音或授权数据的标注清单格式 |
| `requirements.txt`、`requirements-lock.txt` | 评测依赖和本轮验证的完整版本列表 |

根目录 Flutter 工程将 `models/assets/models/` 统一打包成应用资源。`android/` 从 manifest 生成 BuildConfig，构建入口的 `verifyYamnet` 任务检查权重、标签和配置。Android 应用从 Flutter assets 加载模型时再次检查文件校验值和输入输出规格。

官方模型说明与权重下载地址已经写入 manifest。权重校验值为 `4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf`。[YAMNet 上游工程](https://github.com/tensorflow/models/tree/master/research/audioset/yamnet)

## 试用反馈

在应用中开始监测，结束后打开当晚明细，回听片段并标记“其他声音”或“无法判断”。遇到漏检时，在当晚备注记录片段时间及实际听到的声音。

每次新录音会保存模型 ID、权重校验值、参数配置校验值、检测版本和参数。完整声音窗保存三类模型分数、最高分声音类别、录音电平、削波比例和最终判断。人工纠正独立保存在 `overrides.json`，原始判断仍可恢复。已有旧记录继续按原有格式读取。

应用回听片段约一分钟，适合记录误判反馈。精细评测使用下面的起止时间标注，将鼾声事件逐段圈出。

## 本地评测

使用 Python 3.11 或更新版本，在工程根目录执行下面的命令。本轮运行环境为 Windows、Python 3.13、LiteRT 2.3.0。

```powershell
python -m venv models/.venv
models/.venv/Scripts/python.exe -m pip install -r models/requirements-lock.txt
models/.venv/Scripts/python.exe models/evaluate.py --verify-only
models/.venv/Scripts/python.exe -m unittest discover -s models -p test_evaluate.py
```

对自己的单个录音运行识别。

```powershell
models/.venv/Scripts/python.exe models/evaluate.py --audio models/data/night.wav --output models/runs/night-001
```

输入格式为 16 kHz、单声道、PCM16 WAV。其他格式可先转换成该格式，例如使用本机 FFmpeg。

```powershell
ffmpeg -i recording.m4a -ac 1 -ar 16000 -c:a pcm_s16le models/data/night.wav
```

输出目录须使用新目录。每个录音输出逐窗 `*.frames.csv`，全部成功后生成 `summary.json`。报告包含模型与参数指纹、运行时版本、声音类别时长、原始分数、尾部未满一窗的时长和本机推理耗时。失败时可检查 `.partial` 文件及已完成文件。

桌面评测以 0.975 秒的完整声音窗运行分类和声音质量判断。应用整夜记录还会执行开始时的环境校准、暂停管理和评分。桌面运行时为 LiteRT 2.3.0，Android 当前使用 LiteRT 1.4.1，报告中的推理耗时对应实际执行设备。

## 带人工标注的评测

复制 `dataset.example.json`，填写文件路径、人员编号、数据划分、授权来源和鼾声事件起止秒数。`annotationComplete` 为 true 表示整段录音已经完整检查，列表之外的可分析声音作为非鼾声参与统计。填写 false 时仅生成预测结果。

```powershell
models/.venv/Scripts/python.exe models/evaluate.py --dataset models/my-dataset.json --split test --output models/runs/test-001
```

同一个人的录音需要分到同一组，工具会检查跨 train、validation、test 的人员重叠。事件按起始时间排序，起止时间应位于录音内，事件之间保持不重叠。

有完整标注的录音会生成按时间加权的 precision、recall、F1、每小时误报秒数及鼾声时长误差。无法判断的窗遇到人工标注鼾声时，按漏检计入保守评测。无效声音和不足一窗的尾部时长单独报告。有标签的录音数量也会记录在汇总中。

`data/`、`runs/`、虚拟环境已加入忽略规则。原始录音、标注和评测报告保存在本地。模型评测脚本仅读取指定文件。

## 后续微调

先保留这一基线的测试包和结果，根据实际测试归纳误报、漏报、设备距离及环境差异，再确定是否需要调整参数或微调模型。

后续训练数据需记录来源与授权，并按人员划分训练、验证和独立测试集。修改检测参数时更新 `detector.version`。替换权重时同时更新权重校验值、模型版本、标签和输入输出规格，并运行构建检查、设备测试及同一独立测试集。

研究资源入口包括 ESC-50、ICSD、AudioSet、SSBPR。ESC-50 含非商业许可限制，ICSD 的访问条款明确限于非商业研究。商业训练所需的数据范围应按各自授权确认。[ESC-50](https://github.com/karolpiczak/ESC-50)、[ICSD 数据及条款](https://huggingface.co/datasets/QingyuLiu1/ICSD)、[AudioSet](https://research.google.com/audioset/download.html)、[SSBPR](https://github.com/xiaoli1996/SSBPR)
