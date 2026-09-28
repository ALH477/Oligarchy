// Tympanum -- the timpani (MIDI ch 4). A struck membrane: the fundamental
// with a brief pitch drop, two inharmonic partials that die fast, and a
// low-passed noise thud. The decay runs from the strike, not from note-off.
declare name "tympanum";
declare options "[midi:on][nvoices:12]";
import("stdfaust.lib");

freq = hslider("freq", 98, 20, 1000, 0.01);
gain = hslider("gain", 0.5, 0, 1, 0.01);
gate = button("gate");

f     = freq * (1 + 0.05 * en.ar(0.001, 0.07, gate));
decay = en.ar(0.001, 1.8, gate);
tone  = os.osc(f) * decay
      + 0.45 * os.osc(f * 1.505) * en.ar(0.001, 0.45, gate)
      + 0.25 * os.osc(f * 1.99) * en.ar(0.001, 0.25, gate);
thud  = no.noise : fi.lowpass(2, 350) : *(en.ar(0.001, 0.06, gate) * 0.9);

process = tone + thud : *(gain * 0.28);

// No per-instrument bus effect: the hall is aula.dsp.
effect = _;
