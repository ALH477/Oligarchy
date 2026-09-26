// Scurra -- the jester's piccolo (MIDI ch 2). A nearly pure tone with a
// little second and third harmonic, breath noise band-limited around the
// note, a chiff on the attack, and a vibrato that wakes up late -- so the
// staccato runs stay dry and only the held notes wobble.
declare name "scurra";
declare options "[midi:on][nvoices:6]";
import("stdfaust.lib");

freq = hslider("freq", 880, 20, 5000, 0.01);
gain = hslider("gain", 0.5, 0, 1, 0.01);
gate = button("gate");

env    = en.adsr(0.012, 0.05, 0.85, 0.06, gate);
vib    = 1 + 0.007 * os.osc(6.3) * en.asr(0.22, 1, 0.05, gate);
f      = freq * vib;
tone   = os.osc(f) + 0.18 * os.osc(2 * f) + 0.05 * os.osc(3 * f);
breath = no.noise : fi.bandpass(2, f * 0.8, f * 1.6) : *(0.08);
chiff  = no.noise : fi.highpass(2, 3000) : *(en.ar(0.002, 0.03, gate) * 0.25);

process = (tone + breath) * env + chiff : *(gain * 0.32);

// No per-instrument bus effect: the hall is aula.dsp.
effect = _;
