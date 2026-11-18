"""Run the bundled YAMNet on local PCM16 WAV recordings and optional annotations."""

import argparse
import bisect
import csv
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import platform
import struct
import time
import wave


MODEL_DIRECTORY = Path(__file__).resolve().parent / "assets" / "models"


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def verify_assets(directory=MODEL_DIRECTORY):
    manifest_path = directory / "manifest.json"
    config = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_input = {
        "sampleRateHz": 16000, "channels": 1, "frameSamples": 15600,
        "type": "float32", "pcm16Divisor": 32768,
    }
    if config["schemaVersion"] != 1 or config["input"] != expected_input:
        raise ValueError("模型输入规格与当前评测器不匹配")
    if config["output"]["scoresTensorIndex"] != 0 or config["labels"]["count"] != 521:
        raise ValueError("模型输出规格与当前评测器不匹配")
    for kind in ("weights", "labels"):
        artifact = config[kind]
        if Path(artifact["file"]).name != artifact["file"]:
            raise ValueError("模型资产必须位于模型目录内")
        if sha256(directory / artifact["file"]) != artifact["sha256"]:
            raise ValueError(f"模型资产校验失败 {artifact['file']}")
    labels = (directory / config["labels"]["file"]).read_text(encoding="utf-8").splitlines()
    if len(labels) != 521 or any(config["labels"][key] != name for key, name in
                               (("snore", "Snoring"), ("speech", "Speech"), ("music", "Music"))):
        raise ValueError("标签配置不匹配")
    for name in ("Snoring", "Speech", "Music"):
        if labels.count(name) != 1:
            raise ValueError(f"标签缺失或重复 {name}")
    detector = config["detector"]
    if not (0 <= detector["uncertainThreshold"] < detector["snoreThreshold"] <= 1
            and 0 < detector["competitionRatio"] <= 1
            and 0 < detector["clippingThreshold"] < 1
            and type(detector["calibrationFrames"]) is int
            and detector["calibrationFrames"] >= 1
            and math.isfinite(detector["baselineFloorDbfs"])
            and math.isfinite(detector["strongGainDb"]) and detector["strongGainDb"] > 0):
        raise ValueError("检测参数无效")
    config["configSha256"] = sha256(manifest_path)
    return config, labels


def float32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def decision(snore, speech, music, unusable, detector):
    if unusable:
        return "invalid"
    competition = float32(max(speech, music) * float32(detector["competitionRatio"]))
    if snore >= float32(detector["snoreThreshold"]) and snore >= competition:
        return "snore"
    if snore >= float32(detector["uncertainThreshold"]):
        return "uncertain"
    return "other"


def audio_details(path):
    with wave.open(str(path), "rb") as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth(), audio.getcomptype()) != (16000, 1, 2, "NONE"):
            raise ValueError(f"需要 16kHz 单声道 PCM16 WAV {path}")
        return audio.getnframes() / 16000


def load_recordings(args):
    if args.audio:
        recordings = [{"id": "recording", "audio": args.audio.resolve(), "annotationComplete": False}]
    else:
        dataset = json.loads(args.dataset.read_text(encoding="utf-8"))
        if dataset.get("schemaVersion") != 1:
            raise ValueError("数据清单版本不支持")
        recordings = dataset["recordings"]
        subjects = {}
        for recording in recordings:
            subject = recording["subjectId"]
            split = recording["split"]
            if not subject or split not in ("train", "validation", "test") or not recording.get("rights"):
                raise ValueError("数据清单需要人员编号、数据划分和授权来源记录")
            if subject in subjects and subjects[subject] != split:
                raise ValueError(f"同一个人跨越了不同的数据划分 {subject}")
            subjects[subject] = split
            recording["audio"] = (args.dataset.resolve().parent / recording["audio"]).resolve()
        recordings = [recording for recording in recordings if recording["split"] == args.split]
    if not recordings:
        raise ValueError("当前划分中没有录音")
    identifiers = set()
    for recording in recordings:
        identifier = recording["id"]
        if not identifier or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for character in identifier):
            raise ValueError("录音编号只允许字母、数字、横线和下划线")
        if identifier in identifiers:
            raise ValueError(f"录音编号重复 {identifier}")
        identifiers.add(identifier)
        duration = audio_details(recording["audio"])
        if not isinstance(recording.get("annotationComplete"), bool):
            raise ValueError("annotationComplete 必须明确填写 true 或 false")
        events = recording.get("snoreEvents", [])
        previous_end = 0
        for event in events:
            start, end = event["startSeconds"], event["endSeconds"]
            if not (math.isfinite(start) and math.isfinite(end) and previous_end <= start < end <= duration):
                raise ValueError(f"鼾声时间标注越界、重叠或顺序错误 {identifier}")
            previous_end = end
        recording["durationSeconds"] = duration
    return recordings


def overlap_seconds(start, end, events, event_ends):
    overlap = 0.0
    index = bisect.bisect_right(event_ends, start)
    while index < len(events) and events[index]["startSeconds"] < end:
        event = events[index]
        overlap += max(0, min(end, event["endSeconds"]) - max(start, event["startSeconds"]))
        index += 1
    return overlap


def metrics(counts):
    true_positive, false_positive, false_negative, true_negative = counts
    predicted = true_positive + false_positive
    actual = true_positive + false_negative
    evaluated = sum(counts)
    f1_denominator = 2 * true_positive + false_positive + false_negative
    return {
        "truePositiveSeconds": true_positive,
        "falsePositiveSeconds": false_positive,
        "falseNegativeSeconds": false_negative,
        "trueNegativeSeconds": true_negative,
        "precision": true_positive / predicted if predicted else None,
        "recall": true_positive / actual if actual else None,
        "f1": 2 * true_positive / f1_denominator if f1_denominator else None,
        "falsePositiveSecondsPerEvaluatedHour": false_positive / evaluated * 3600 if evaluated else None,
        "snoreDurationErrorSeconds": predicted - actual,
    }


def evaluate_recording(recording, config, labels, interpreter, input_tensor, output_tensor, output_directory):
    import numpy as np

    frame_samples = config["input"]["frameSamples"]
    detector = config["detector"]
    indices = {key: labels.index(config["labels"][key]) for key in ("snore", "speech", "music")}
    durations = dict.fromkeys(("snore", "other", "uncertain", "invalid"), 0.0)
    counts = [0.0, 0.0, 0.0, 0.0]
    events = recording.get("snoreEvents", [])
    event_ends = [event["endSeconds"] for event in events]
    offset_samples = 0
    frame_count = 0
    total_samples = 0
    inference_seconds = 0.0
    audio_sha256 = sha256(recording["audio"])
    frame_path = output_directory / f"{recording['id']}.frames.csv"
    pending_path = frame_path.with_suffix(".csv.partial")
    with wave.open(str(recording["audio"]), "rb") as audio, pending_path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output)
        writer.writerow(["startSeconds", "endSeconds", "label", "snoreScore", "speechScore", "musicScore",
                         "topLabel", "rmsDbfs", "clippingRatio", "annotatedSnoreSeconds"])
        while raw := audio.readframes(frame_samples):
            samples = np.frombuffer(raw, dtype="<i2")
            total_samples += len(samples)
            if len(samples) != frame_samples:
                break
            normalized = samples.astype(np.float32) / np.float32(config["input"]["pcm16Divisor"])
            clipping = float(np.count_nonzero(np.abs(samples.astype(np.int32)) >= 32760) / frame_samples)
            unusable = not np.any(samples) or clipping > detector["clippingThreshold"]
            interpreter.set_tensor(input_tensor["index"], normalized.reshape(input_tensor["shape"]))
            before = time.perf_counter()
            interpreter.invoke()
            inference_seconds += time.perf_counter() - before
            scores = interpreter.get_tensor(output_tensor["index"]).reshape(-1)
            if not np.all(np.isfinite(scores)):
                raise ValueError("模型输出包含无效数值")
            snore, speech, music = (float(scores[indices[key]]) for key in ("snore", "speech", "music"))
            label = decision(snore, speech, music, unusable, detector)
            start = offset_samples / 16000
            offset_samples += frame_samples
            end = offset_samples / 16000
            frame_count += 1
            durations[label] += end - start
            annotated = ""
            if recording["annotationComplete"] and label != "invalid":
                annotated = min(end - start, overlap_seconds(start, end, events, event_ends))
                negative = max(0, end - start - annotated)
                if label == "snore":
                    counts[0] += annotated
                    counts[1] += negative
                else:
                    counts[2] += annotated
                    counts[3] += negative
            energy = float(np.sum((normalized * normalized).astype(np.float64))) / frame_samples
            rms_dbfs = 20 * math.log10(max(1e-8, math.sqrt(energy)))
            writer.writerow([start, end, label, snore, speech, music,
                             labels[int(np.argmax(scores))], rms_dbfs, clipping, annotated])
        if total_samples != audio.getnframes():
            raise ValueError(f"WAV 数据不完整 {recording['id']}")
    if sha256(recording["audio"]) != audio_sha256:
        raise ValueError(f"录音在评测期间发生了修改 {recording['id']}")
    pending_path.replace(frame_path)
    annotated_metrics = metrics(counts) if recording["annotationComplete"] else None
    return {
        "id": recording["id"], "subjectId": recording.get("subjectId"),
        "audio": str(recording["audio"]), "audioSha256": audio_sha256,
        "split": recording.get("split"), "rights": recording.get("rights"),
        "durationSeconds": recording["durationSeconds"], "frameCount": frame_count,
        "durationsSeconds": durations,
        "partialFrameSeconds": recording["durationSeconds"] - offset_samples / 16000,
        "meanInferenceMs": inference_seconds * 1000 / frame_count if frame_count else None,
        "annotationComplete": recording["annotationComplete"],
        "snoreEvents": events if recording["annotationComplete"] else None,
        "metrics": annotated_metrics,
    }, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--verify-only", action="store_true")
    source.add_argument("--audio", type=Path)
    source.add_argument("--dataset", type=Path)
    parser.add_argument("--split", choices=("train", "validation", "test"), default="test")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        config, labels = verify_assets()
        if args.verify_only:
            print(json.dumps({"model": config["displayName"], "sha256": config["weights"]["sha256"],
                              "configSha256": config["configSha256"], "labels": len(labels)}, ensure_ascii=False, indent=2))
            return
        if not args.output:
            parser.error("评测需要指定一个新的 --output 目录")
        recordings = load_recordings(args)
        import numpy as np
        from ai_edge_litert.interpreter import Interpreter

        interpreter = Interpreter(model_path=str(MODEL_DIRECTORY / config["weights"]["file"]), num_threads=2)
        interpreter.allocate_tensors()
        input_tensor = interpreter.get_input_details()[0]
        output_tensor = interpreter.get_output_details()[config["output"]["scoresTensorIndex"]]
        if (input_tensor["dtype"] != np.float32 or output_tensor["dtype"] != np.float32
                or np.prod(input_tensor["shape"]) != config["input"]["frameSamples"]
                or np.prod(output_tensor["shape"]) != len(labels)):
            raise ValueError("运行时模型张量规格不匹配")
        args.output.mkdir(parents=True, exist_ok=False)
        results = []
        totals = [0.0, 0.0, 0.0, 0.0]
        for index, recording in enumerate(recordings, start=1):
            print(f"{index}/{len(recordings)} {recording['id']}", flush=True)
            result, counts = evaluate_recording(recording, config, labels, interpreter, input_tensor, output_tensor, args.output)
            results.append(result)
            totals = [left + right for left, right in zip(totals, counts)]
        annotated_count = sum(recording["annotationComplete"] for recording in recordings)
        summary = {
            "schemaVersion": 1, "mode": "window-classification", "model": config,
            "runtime": {"name": "ai-edge-litert", "version": importlib.metadata.version("ai-edge-litert"),
                        "numpy": np.__version__, "platform": platform.platform()},
            "recordings": results, "annotatedRecordings": annotated_count,
            "pooledTimeWeightedMetrics": metrics(totals) if annotated_count else None,
            "metricPolicy": "Complete annotations only. Invalid and partial frames excluded. Uncertain windows count as missed snoring when overlapping annotated snores.",
        }
        summary_path = args.output / "summary.json"
        summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        print(str(summary_path.resolve()))
    except (ValueError, OSError, KeyError, TypeError, wave.Error, ImportError) as error:
        parser.exit(1, f"评测失败 {error}\n")


if __name__ == "__main__":
    main()
