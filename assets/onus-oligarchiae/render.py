#!/usr/bin/env python3
"""Perform "Onus Oligarchiae": the Exsecutor-written score, played by the
FAUST orchestra in orchestra/.

    pip install dawdreamer mido soundfile
    python3 render.py [onus_oligarchiae.mid] [out.ogg|out.flac|out.wav]

The MIDI file is the one Exsecutor's examples/onus/ program writes (and its
oracle, prototypes/onus_oracle.py, writes identically). Each instrument track
is split into its own file -- conductor track kept, so the tempo map travels
with it -- and loaded into its own polyphonic FAUST processor; DawDreamer's
FAUST processor does not filter by channel, which is why the split is
needed. aula.dsp mixes the five sections, adds the room and limits.

Offline only. For a live performance on Oligarchy's JACK graph, each .dsp in
orchestra/ builds as a MIDI-driven polyphonic JACK client:
    faust2jaqt -midi -nvoices 12 orchestra/ostinatum.dsp
"""

import os
import sys
import tempfile

import dawdreamer as daw
import mido
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
SR = 48000
BLOCK = 256
TAIL = 4.0  # seconds of reverb and timpani decay after the last bar
SECTIONS = ["ostinatum", "aes", "scurra", "fagottus", "tympanum"]


def split(mid_path, workdir):
    src = mido.MidiFile(mid_path)
    assert src.type == 1 and len(src.tracks) == 1 + len(SECTIONS), \
        "expected the conductor track plus one track per section"
    paths = []
    for i, name in enumerate(SECTIONS, start=1):
        out = mido.MidiFile(type=1, ticks_per_beat=src.ticks_per_beat)
        out.tracks.append(src.tracks[0])
        out.tracks.append(src.tracks[i])
        p = os.path.join(workdir, f"{name}.mid")
        out.save(p)
        paths.append(p)
    return paths, src.length


def main(argv):
    mid = argv[1] if len(argv) > 1 else os.path.join(HERE, "onus_oligarchiae.mid")
    out = argv[2] if len(argv) > 2 else os.path.join(HERE, "onus_oligarchiae.ogg")

    engine = daw.RenderEngine(SR, BLOCK)
    graph = []
    with tempfile.TemporaryDirectory() as tmp:
        parts, length = split(mid, tmp)
        for name, part in zip(SECTIONS, parts):
            with open(os.path.join(HERE, "orchestra", f"{name}.dsp")) as f:
                code = f.read()
            proc = engine.make_faust_processor(name)
            proc.num_voices = 16
            proc.release_length = TAIL
            if not proc.set_dsp_string(code):
                raise SystemExit(f"{name}.dsp did not compile")
            proc.load_midi(part, clear_previous=True, beats=False, all_events=True)
            graph.append((proc, []))

        with open(os.path.join(HERE, "orchestra", "aula.dsp")) as f:
            aula = engine.make_faust_processor("aula")
            if not aula.set_dsp_string(f.read()):
                raise SystemExit("aula.dsp did not compile")
        graph.append((aula, SECTIONS))

        engine.load_graph(graph)
        engine.render(length + TAIL)

    audio = engine.get_audio().T.astype(np.float64)
    peak = float(np.max(np.abs(audio)))
    if peak == 0.0:
        raise SystemExit("rendered silence")
    # One gain for the whole piece, to a -1 dBFS peak: loudness only, so the
    # crescendo aula.dsp leaves alone is left alone here too.
    audio *= 10 ** (-1 / 20) / peak
    audio = audio.astype(np.float32)
    # In blocks: libsndfile's Vorbis encoder segfaults on one 4M-frame write.
    with sf.SoundFile(out, "w", SR, audio.shape[1]) as f:
        for i in range(0, len(audio), 8192):
            f.write(audio[i:i + 8192])
    print(f"{out}: {audio.shape[0] / SR:.1f} s, "
          f"peak {20 * np.log10(peak):.1f} dBFS before normalising to -1")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
