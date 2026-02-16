# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025 DeMoD LLC. All rights reserved.
#
# ArchibaldOS Headless DSP VM Configuration
# Built from source with CachyOS RT kernel
# Optimized for NETJACK audio routing to host
#
# Usage: 
#   nix build .#archibaldos-dsp-vm
#   qemu-img convert -O raw result/~/vms/archibaldos-dsp.qcow2
#
{ config, lib, pkgs, ... }:

let
  # Import ArchibaldOS modules
  audioModule = import ./archibaldos-dsp-audio.nix { inherit config lib pkgs; };
  
in
{
  # Use CachyOS RT kernel with BORE scheduler
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_cachyos-rt;

  # RT kernel parameters
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
    "hugepagesz=2M"
    "hugepages=1024"
  ];

  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # Base system configuration
  system.stateVersion = "24.11";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  networking.networkmanager.enable = true;
  networking.firewall.enable = false;

  # ============================================================
  # DSP Audio - Ultra Low Latency NETJACK Configuration
  # ============================================================
  
  # Disable PulseAudio
  hardware.pulseaudio.enable = false;

  # RTKit for real-time priority
  security.rtkit.enable = true;

  # PipeWire with ultra-low latency (128 samples @ 96kHz)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = false;
    jack.enable = false;

    extraConfig.pipewire."92-dsp-latency" = {
      "context.properties" = {
        "default.clock.rate" = 96000;
        "default.clock.quantum" = 128;
        "default.clock.min-quantum" = 64;
        "default.clock.max-quantum" = 256;
      };
    };
  };

  # Standalone JACK2 for NETJACK - deterministic timing
  services.jack2 = {
    enable = true;
    user = "dsp";
    settings = {
      frames = 128;
      period = 128;
      sampleRate = 96000;
      realtime = true;
    };
  };

  # RT kernel parameters for deterministic DSP
  boot.kernelParams = [
    "threadirqs"
    "isolcpus=1"
    "nohz_full=1"
    "rcu_nocbs=1"
    "intel_idle.max_cstate=1"
    "processor.max_cstate=1"
    "tsc=reliable"
    "preempt=full"
  ];

  # Audio-optimized sysctl
  boot.kernel.sysctl = {
    "vm.swappiness" = lib.mkForce 0;
    "vm.dirty_ratio" = lib.mkForce 5;
    "vm.dirty_background_ratio" = lib.mkForce 2;
  };

  environment.etc."sysctl.d/99-audio-dsp.conf".text = ''
    dev.rtc.max-user-freq = 2048
    dev.hpet.max-user-freq = 2048
    net.core.rmem_max = 16777216
    net.core.wmem_max = 16777216
  '';

  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # ALSA configuration for HD audio
  environment.etc."asound.conf".text = ''
    defaults.pcm.dmix.rate 96000
    defaults.pcm.dmix.format S32_LE
    defaults.pcm.dmix.buffer_size 128
  '';

  # Kernel modules for audio
  boot.kernelModules = [
    "snd_usb_audio"
    "snd_hda_intel"
    "usbhid"
    "usbmidi"
  ];
  
  boot.extraModprobeConfig = ''
    options snd_usb_audio nrpacks=1 low_latency=1
  '';

  # Real-time limits
  security.pam.loginLimits = [
    { domain = "@audio"; type = "-"; item = "rtprio"; value = "99"; }
    { domain = "@audio"; type = "-"; item = "memlock"; value = "unlimited"; }
    { domain = "@audio"; type = "-"; item = "nice"; value = "-20"; }
  ];

  users.groups.audio = {};
  users.groups.jackaudio = {};
  users.groups.realtime = {};

  users.users.dsp = {
    isNormalUser = true;
    description = "DSP Audio User";
    group = "audio";
    extraGroups = [ "jackaudio" "realtime" "wheel" ];
    shell = pkgs.bash;
  };

  # Audio packages
  environment.systemPackages = with pkgs; [
    alsa-utils
    jack2
    htop
    vim
    git
  ];

  # ============================================================
  # Headless Configuration - No Display
  # ============================================================
  
  # Disable X11/Wayland completely
  services.xserver.enable = lib.mkForce false;
  
  # Disable display manager
  services.displayManager.enable = lib.mkForce false;
  
  # Console autologin
  services.getty.autologinUser = "dsp";
  
  # Disable unneeded services
  services.udisks2.enable = lib.mkForce false;
  services.blueman.enable = lib.mkForce false;
  services.avahi.enable = lib.mkForce false;
  
  # NTP for sample-accurate timing
  services.timesyncd.enable = true;
}
