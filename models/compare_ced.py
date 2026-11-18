"""Compare the app's YAMNet window rule with CED-tiny's mapped top category."""

import argparse
import json
from pathlib import Path
from time import perf_counter
import wave

from evaluate import MODEL_DIRECTORY, decision, verify_assets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ced', type=Path, required=True, help='CED-tiny ONNX')
    parser.add_argument('--class-map', type=Path, required=True, help='Sleep Secret sleep_class_map.json')
    parser.add_argument('wav', nargs='+', type=Path, help='16 kHz mono PCM16 WAV files, at least 3 s each')
    args = parser.parse_args()

    import numpy as np
    import onnxruntime as ort
    from ai_edge_litert.interpreter import Interpreter

    config, labels = verify_assets()
    indices = [labels.index(config['labels'][label]) for label in ('snore', 'speech', 'music')]
    yam = Interpreter(model_path=str(MODEL_DIRECTORY / config['weights']['file']), num_threads=2)
    yam.allocate_tensors()
    yam_input = yam.get_input_details()[0]
    yam_output = yam.get_output_details()[config['output']['scoresTensorIndex']]
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    ced = ort.InferenceSession(str(args.ced), sess_options=options, providers=['CPUExecutionProvider'])
    categories = json.loads(args.class_map.read_text(encoding='utf-8'))['categories']

    wav_window = 48000
    yam_window = config['input']['frameSamples']
    timings = {'yamnet': [], 'cedTiny': []}
    for path in args.wav:
        with wave.open(str(path), 'rb') as wav:
            if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getcomptype()) != (16000, 1, 2, 'NONE'):
                parser.error(f'{path} must be 16 kHz mono PCM16 WAV')
            pcm = np.frombuffer(wav.readframes(wav.getnframes()), dtype='<i2')
        blocks = len(pcm) // wav_window
        if blocks == 0:
            parser.error(f'{path} is shorter than 3 seconds')
        for attenuation in (0, -12, -24):
            signal = np.round(pcm * 10 ** (attenuation / 20)).astype(np.float32) / 32768
            hits = {'yamnet': 0, 'cedTiny': 0}
            for block in range(blocks):
                frame = signal[block * wav_window:(block + 1) * wav_window]
                start = perf_counter()
                scores = ced.run(['logits'], {'waveform': frame[None, :]})[0][0]
                timings['cedTiny'].append(perf_counter() - start)
                group_scores = {category: max(scores[ids]) for category, ids in categories.items()}
                hits['cedTiny'] += max(group_scores, key=group_scores.get) == 'snore'

                yam_hit = False
                for offset in range(0, wav_window - yam_window + 1, yam_window):
                    window = frame[offset:offset + yam_window]
                    start = perf_counter()
                    yam.set_tensor(yam_input['index'], window.reshape(yam_input['shape']))
                    yam.invoke()
                    scores = yam.get_tensor(yam_output['index']).reshape(-1)[indices]
                    timings['yamnet'].append(perf_counter() - start)
                    clipped = np.count_nonzero(np.abs(window) >= 32760 / 32768) / len(window)
                    unusable = not np.any(window) or clipped > config['detector']['clippingThreshold']
                    yam_hit |= decision(*scores, unusable, config['detector']) == 'snore'
                hits['yamnet'] += yam_hit
            print(json.dumps({'file': path.name, 'attenuationDb': attenuation, 'blocks': blocks, 'hits': hits}))

    print(json.dumps({'desktopMedianMsPerInference': {
        model: round(float(np.median(durations)) * 1000, 2) for model, durations in timings.items()
    }}))


if __name__ == '__main__':
    main()
