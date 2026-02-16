# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025 DeMoD LLC. All rights reserved.
# Real-time audio configuration
{ config, lib, pkgs, ... }:

{
  # Disable PulseAudio in favor of PipeWire
  hardware.pulseaudio.enable = false;

  # PipeWire with pro-level low latency (32 samples @ 96kHz)
  security.rtkit.enable = true;
  
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;

    extraConfig.pipewire."92-low-latency" = {
      "context.properties" = {
        "default.clock.rate" = 96000;
        "default.clock.quantum" = 32;
        "default.clock.min-quantum" = 16;
        "default.clock.max-quantum" = 64;
      };
    };
  };

  # RT kernel parameters
  boot.kernelParams = lib.mkDefault [
    "threadirqs"
    "isolcpus=1-3"
    "nohz_full=1-3"
    "intel_idle.max_cstate=1"
    "processor.max_cstate=1"
  ];

  # Audio-optimized sysctl
  boot.kernel.sysctl = {
    "vm.swappiness" = lib.mkForce 0;
    "fs.inotify.max_user_watches" = 600000;
  };

  environment.etc."sysctl.d/99-audio.conf".text = ''
    dev.rtc.max-user-freq = 2048
    dev.hpet.max-user-freq = 2048
  '';

  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # ALSA defaults for 96kHz
  environment.etc."asound.conf".text = ''
    defaults.pcm.dmix.rate 96000
    defaults.pcm.dmix.format S32_LE
    defaults.pcm.dmix.buffer_size 32
  '';

  # Ardour defaults
  environment.etc."ardour6/ardour.rc".text = ''
    <JACK buffer-size="32" sample-rate="96000" periods="2"/>
  '';

  # Kernel modules
  boot.kernelModules = [ "snd_usb_audio" "usbhid" "usbmidi" "snd_hda_intel" ];
  boot.extraModprobeConfig = ''
    options snd_usb_audio nrpacks=1 low_latency=1
  '';

  # RT limits for audio group
  security.pam.loginLimits = [
    { domain = "@audio"; type = "-"; item = "rtprio"; value = "99"; }
    { domain = "@audio"; type = "-"; item = "memlock"; value = "unlimited"; }
    { domain = "@audio"; type = "-"; item = "nice"; value = "-19"; }
  ];

  # Audio groups
  users.groups.audio = {};
  users.groups.jackaudio = {};
  users.groups.realtime = {};

  # Audio packages
  environment.systemPackages = with pkgs; [
    alsa-utils
    pavucontrol
    jack2
    qjackctl
  ];
}
