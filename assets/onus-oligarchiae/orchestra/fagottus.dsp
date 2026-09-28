// Fagottus -- the bassoon (MIDI ch 3), the jester's straight man. A narrow
// pulse -- a reed -- through two formant resonators and a low-pass body.
declare name "fagottus";
declare options "[midi:on][nvoices:6]";
import("stdfaust.lib");

freq = hslider("freq", 110, 20, 2000, 0.01);
gain = hslider("gain", 0.5, 0, 1, 0.01);
gate = button("gate");

env  = en.adsr(0.03, 0.1, 0.8, 0.07, gate);
reed = os.pulsetrain(freq, 0.28) : fi.dcblocker;
body = reed <: fi.resonbp(480, 4, 1), fi.resonbp(1150, 5, 0.45), fi.lowpass(2, 700) :> _;

process = body : *(env * gain * 0.15);

// No per-instrument bus effect: the hall is aula.dsp.
effect = _;
