// Ostinatum -- the col legno strings that carry the Mars rhythm (MIDI ch 0).
// The wood of the bow, not the hair: a click of band-passed noise excites a
// heavily damped Karplus-Strong string, under a short sine thump that gives
// the low G its weight.
declare name "ostinatum";
declare options "[midi:on][nvoices:12]";
import("stdfaust.lib");

freq = hslider("freq", 98, 20, 2000, 0.01);
gain = hslider("gain", 0.5, 0, 1, 0.01);
gate = button("gate");

click  = no.noise : fi.bandpass(1, 1200, 4200) : *(en.ar(0.0005, 0.012, gate));
string = + ~ (de.fdelay(4096, ma.SR / freq - 1) : fi.lowpass(1, 2400) : *(0.935));
thump  = os.osc(freq) * en.ar(0.002, 0.16, gate) * 0.55;
damp   = en.asr(0.0005, 1, 0.06, gate);

process = (click : string) * damp + thump : *(gain * 0.9);

// No per-instrument bus effect: the hall is aula.dsp.
effect = _;
