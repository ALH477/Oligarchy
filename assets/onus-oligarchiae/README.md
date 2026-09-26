# Onus Oligarchiae

*The burden of the oligarchy.* Oligarchy's theme song: a march in 5/4 in G
after Holst's *Mars, the Bringer of War*, but whimsical. It has a col legno
ostinato hammering the Mars rhythm on a G pedal, and brass climbing a
semitone a bar to a dissonant peak. A jester's piccolo is loose in the court
throughout, and a bassoon keeps trying to march in 3 + 2. After the last
hammered chord there is a bar of silence, the jester gets a *ta-da*, and the
piece ends on one G. It lasts 81.7 seconds plus the room's tail.

Two languages made it. The score was written as a program in
[Exsecutor](https://github.com/ALH477/exsecutor), in `examples/onus/`, which
writes it out as a Standard MIDI File. The orchestra is FAUST, in
`orchestra/` here.

| file | what |
|---|---|
| `onus_oligarchiae.mid` | the score: format 1, six tracks, 96 ticks a quarter, 7,897 bytes. Byte-identical to Exsecutor's `examples/onus/onus_oligarchiae.mid` |
| `onus_oligarchiae.ogg` | the performance: 48 kHz stereo Vorbis, 85.7 s, peak −1 dBFS |
| `orchestra/*.dsp` | the FAUST instruments, one per section, plus `aula.dsp`, the hall |
| `render.py` | plays the `.mid` through the orchestra offline |

## The orchestra

Each instrument is an ordinary FAUST MIDI instrument (`freq`/`gain`/`gate`,
`[midi:on][nvoices:N]`), so each one also builds as a live JACK client.

| section | MIDI ch | GM program | FAUST voice |
|---|---|---|---|
| `ostinatum` | 0 | 45 pizzicato strings | col legno: a band-passed noise click into a damped Karplus-Strong string, over a sine thump |
| `aes` | 1 | 57 trombone | two detuned saws and a sub-octave square through a resonant low-pass whose cutoff follows velocity²; an attack blat; delayed vibrato |
| `scurra` | 2 | 72 piccolo | near-sine with breath noise, an attack chiff and a vibrato that wakes late, so staccato stays dry |
| `fagottus` | 3 | 70 bassoon | a narrow pulse (the reed) through two formant resonators |
| `tympanum` | 4 | 47 timpani | struck membrane: pitch drop, inharmonic partials, noise thud; decays from the strike, not the note-off |
| `aula` | — | — | seating (equal-power pan), balance, Zita reverb, 1176-style limiter driven at half level so it catches peaks without flattening the crescendo |

The GM programs mean the `.mid` also plays on any General MIDI synth, such
as FluidSynth.

## Rendering

```sh
pip install dawdreamer mido soundfile   # DawDreamer bundles libfaust
python3 render.py                       # -> onus_oligarchiae.ogg
```

`render.py` splits the file into one MIDI file per section, keeping the
conductor track so the tempo map (150, broadening to about 111) travels with
each. DawDreamer's FAUST processor does not filter by channel, so each
section gets its own polyphonic processor, and the five are summed into
`aula`. The rendered PCM is bit-identical from run to run: it was rendered
twice to WAV and compared with `cmp`. The `.ogg` bytes are not identical,
because every Ogg stream gets a random serial number.

Like `scripts/`, this is an operator tool and not wired into any derivation.
Its Python dependencies come from pip, not from the flake, so it is outside
the "pin everything" rule. The artefacts it produced are what is committed.

Live, on the JACK graph (nixpkgs has `faust`):

```sh
nix shell nixpkgs#faust
faust2jaqt -midi -nvoices 12 orchestra/ostinatum.dsp   # one client per section
```

## Provenance

- Score: Exsecutor `examples/onus/` (`partitura.exsc` and `onus.exsc`, at
  `6be3a8b`),
  checked against `prototypes/onus_oracle.py`. **That program has not yet
  been compiled by `exsc`.** It was written without `fasmg` in reach, and
  the committed `.mid` was written by the oracle. A mechanical
  transliteration of the program produced the same bytes. Exsecutor's
  `examples/onus/README.md` gives the evidence exactly.
- The composition is original. It borrows from Holst's *Mars* in manner
  only: the 5/4 meter, the rhythm cell, the pedal and the chromatic climb.
  It quotes no melody from it.
