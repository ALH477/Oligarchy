// Aes -- the low brass (MIDI ch 1). Two detuned saws and a sub-octave square
// through a resonant low-pass whose cutoff follows the velocity squared, with
// a fast overshoot on the attack for the blat, and a vibrato that only
// arrives once a note has been held.
declare name "aes";
declare options "[midi:on][nvoices:16]";
import("stdfaust.lib");

freq = hslider("freq", 110, 20, 2000, 0.01);
gain = hslider("gain", 0.5, 0, 1, 0.01);
gate = button("gate");

env    = en.adsr(0.035, 0.25, 0.78, 0.18, gate);
blat   = en.ar(0.008, 0.14, gate);
vib    = 1 + 0.0045 * os.osc(5.1) * en.asr(0.45, 1, 0.1, gate);
f      = freq * vib;
tone   = os.sawtooth(f) + 0.8 * os.sawtooth(f * 1.0045) + 0.3 * os.square(f * 0.5);
cutoff = freq * (1.4 + 8.0 * gain * gain * env + 6.0 * blat) : min(14000);

process = tone : fi.resonlp(cutoff, 1.4, 1) : *(env * gain * 0.15);

// No per-instrument bus effect: the hall is aula.dsp.
effect = _;
