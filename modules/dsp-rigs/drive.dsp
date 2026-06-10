// Oligarchy DSP rig — soft-clip overdrive (stereo)
// Example "pedalboard as code". Enable by uncommenting the `drive` rig in
// modules/dsp-rigs.nix (custom.dsp.rigs), then switch to it from the control
// center. The `drive` knob is exposed as a JACK/MIDI control.
declare name "oligarchy_drive";
import("stdfaust.lib");

gain = hslider("drive", 3, 1, 12, 0.1);
level = hslider("level", 0.7, 0, 1, 0.01);

sat = *(gain) : tanh : *(level);

process = sat, sat;
