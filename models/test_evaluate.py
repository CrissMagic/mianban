import argparse
import json
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from evaluate import MODEL_DIRECTORY, decision, float32, load_recordings, metrics, overlap_seconds, verify_assets


class EvaluationTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).resolve().parent / "runs"
        scratch.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def test_manifest_and_packaged_artifacts_match(self):
        config, labels = verify_assets()
        self.assertEqual(labels[38], "Snoring")
        self.assertEqual(config["detector"]["version"], "alpha-1")
        self.assertFalse(config["weights"]["fineTuned"])

    def test_changed_weights_are_rejected(self):
        (self.directory / "manifest.json").write_bytes((MODEL_DIRECTORY / "manifest.json").read_bytes())
        (self.directory / "yamnet.tflite").write_bytes(b"changed model")
        with self.assertRaisesRegex(ValueError, "校验失败"):
            verify_assets(self.directory)

    def test_decision_preserves_android_float32_boundaries(self):
        detector = verify_assets()[0]["detector"]
        self.assertEqual(decision(float32(.35), 0, 0, False, detector), "snore")
        self.assertEqual(decision(float32(.15), 0, 0, False, detector), "uncertain")
        self.assertEqual(decision(float32(.36), float32(.9), 0, False, detector), "uncertain")
        self.assertEqual(decision(.99, 0, 0, True, detector), "invalid")

    def test_temporal_metrics_count_partial_overlaps(self):
        events = [{"startSeconds": .5, "endSeconds": 1.5}]
        self.assertAlmostEqual(overlap_seconds(0, .975, events, [1.5]), .475)
        self.assertAlmostEqual(overlap_seconds(.975, 1.95, events, [1.5]), .525)
        result = metrics([2, 1, 3, 4])
        self.assertAlmostEqual(result["precision"], 2 / 3)
        self.assertAlmostEqual(result["recall"], 2 / 5)
        self.assertEqual(result["snoreDurationErrorSeconds"], -2)
        self.assertIsNone(metrics([0, 0, 0, 1])["recall"])

    def test_one_subject_cannot_cross_dataset_splits(self):
        with wave.open(str(self.directory / "sample.wav"), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(struct.pack("<h", 200) * 16000)
        manifest = self.directory / "dataset.json"
        recordings = [{"id": name, "subjectId": "same-person", "split": split,
                       "audio": "sample.wav", "rights": "generated fixture", "annotationComplete": False}
                      for name, split in (("first", "train"), ("second", "test"))]
        manifest.write_text(json.dumps({"schemaVersion": 1, "recordings": recordings}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "不同的数据划分"):
            load_recordings(argparse.Namespace(audio=None, dataset=manifest, split="test"))


if __name__ == "__main__":
    unittest.main()
