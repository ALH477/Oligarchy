# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025 DeMoD LLC. All rights reserved.
# 
# ArchibaldOS DSP Audio Module - Ultra Low Latency NETJACK Configuration
# Optimized for 128 samples @ 96kHz 24-bit = 1.33ms latency
{ config, lib, pkgs, ... }:

{
  # Disable PulseAudio completely
  hardware.pulseaudio.enable = false;

  # RTKit for real-time priority
  security.rtkit.enable = true;

  # PipeWire with ultra-low latency settings
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = false;
    jack.enable = false;  # We use standalone JACK for NETJACK

    extraConfig.pipewire."92-dsp-latency" = {
      "context.properties" = {
        "default.clock.rate" = 96000;
        "default.clock.quantum" = 128;
        "default.clock.min-quantum" = 64;
        "default.clock.max-quantum" = 256;
        "default.clock.quantum-limit" = 16384;
        "link.max-buffers" = 2;
      };
      "stream.properties" = {
        "node.latency" = "128/96000";
        "resample.quality" = "very-high";
        "monitor.disable" = false;
      };
    };
  };

  # Standalone JACK2 for NETJACK - deterministic timing
  services.jack2 = {
    enable = true;
    server = "netjack";
    user = "dsp";
    
    # 128 frames @ 96kHz = 1.33ms round-trip latency
    settings = {
      frames = 128;
      period = 128;
      sampleRate = 96000;
      realtime = true;
      username = "dsp";
    };
    
    driver = "netone";
    driverArgs = [
      "-C" "2"    # 2 capture channels
      "-P" "2"    # 2 playback channels
      "-r" "96000"
      "-n" "archibaldos-dsp"
    ];
  };

  # Disable PipeWire JACK, use standalone JACK for NETJACK
  # This is critical for deterministic timing
  services.pipewire.wireplumber.enable = true;
  
  # RT kernel parameters for deterministic DSP
  boot.kernelParams = [
    "threadirqs"
    "isolcpus=1"
    "nohz_full=1"
    "rcu_nocbs=1"
    "intel_idle.max_cstate=1"
    "processor.max_cstate=1"
    "tsc=reliable"
    "clocksource=tsc"
    "preempt=full"
  ];

  # Audio-optimized sysctl - minimize latency
  boot.kernel.sysctl = {
    "vm.swappiness" = lib.mkForce 0;
    "vm.dirty_ratio" = lib.mkForce 5;
    "vm.dirty_background_ratio" = lib.mkForce 2;
    "fs.inotify.max_user_watches" = lib.mkForce 600000;
    "fs.inotify.max_user_instances" = lib.mkForce 1024;
  };

  # Kernel sysctl for audio
  environment.etc."sysctl.d/99-audio-dsp.conf".text = ''
    # RTC for audio timing
    dev.rtc.max-user-freq = 2048
    dev.hpet.max-user-freq = 2048
    
    # Network buffer tuning for NETJACK
    net.core.rmem_max = 16777216
    net.core.wmem_max = 16777216
    net.core.rmem_default = 8388608
    net.core.wmem_default = 8388608
    net.ipv4.tcp_rmem = 4096 8388608 16777216
    net.ipv4.tcp_wmem = 4096 8388608 16777216
  '';

  # Performance CPU governor
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # ALSA configuration for HD audio
  environment.etc."asound.conf".text = ''
    # HD Audio - 96kHz 24-bit
    defaults.pcm.dmix.rate 96000
    defaults.pcm.dmix.format S32_LE
    defaults.pcm.dmix.buffer_size 128
    defaults.pcm.dsnoop.rate 96000
    defaults.pcm.dsnoop.format S32_LE
    
    # Jack/DSP interface
    pcm.netjack {
      type net
      ip 0.0.0.0
      port 4713
      mlock yes
      capture_periods 2
      capture_frame_size 128
    }
    
    pcm.!default {
      type plug
      slave.pcm "netjack"
    }
  '';

  # Kernel modules for audio
  boot.kernelModules = [
    "snd_usb_audio"
    "snd_hda_intel"
    "usbhid"
    "usbmidi"
    "snd_seq"
    "snd_rawmidi"
  ];
  
  boot.extraModprobeConfig = ''
    # USB audio low-latency settings
    options snd_usb_audio nrpacks=1 low_latency=1
    options snd_usb_audio vid=0x0ccd pid=0x00a2 enable=1 index=0
    
    # Intel HDA for low latency
    options snd_hda_intel position_fix=1
  '';

  # Real-time limits for audio
  security.pam.loginLimits = [
    { domain = "@audio"; type = "-"; item = "rtprio"; value = "99"; }
    { domain = "@audio"; type = "-"; item = "memlock"; value = "unlimited"; }
    { domain = "@audio"; type = "-"; item = "nice"; value = "-20"; }
  ];

  # Audio groups
  users.groups.audio = {};
  users.groups.jackaudio = {};
  users.groups.realtime = {};

  # DSP user
  users.users.dsp = {
    isNormalUser = true;
    description = "DSP Audio User";
    group = "audio";
    extraGroups = [ "jackaudio" "realtime" "wheel" ];
    shell = pkgs.bash;
  };

  # Minimal audio packages - only what's needed for DSP
  environment.systemPackages = with pkgs; [
    alsa-utils
    jack2
    jack2.carla
    netcat
    htop
  ];

  # Disable unnecessary services
  services.udisks2.enable = lib.mkForce false;
  services.blueman.enable = lib.mkForce false;
  services.avahi.enable = lib.mkForce false;
  
  # Network configuration for NETJACK
  networking.firewall.enable = false;
  
  # NTP for sample-accurate timing
  services.timesyncd.enable = true;
  services.timesyncd.servers = [
    "0.pool.ntp.org"
    "1.pool.ntp.org"
  ];
}
