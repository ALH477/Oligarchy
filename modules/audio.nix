{ config, lib, pkgs, ... }:

let
  cfg = config.custom.audio;
in
{
  options.custom.audio = {
    enable = lib.mkEnableOption "advanced PipeWire audio configuration optimized for gaming, streaming, and light pro-audio work";

    lowLatency = {
      enable = lib.mkEnableOption "low-latency profile (balanced for gaming + production)" // { default = true; };
      proAudio = lib.mkEnableOption "very low latency for professional audio (may increase CPU usage / risk xruns)" // { default = false; };
    };

    bluetooth = {
      highQualityCodecs = lib.mkEnableOption "enable high-quality Bluetooth A2DP codecs (LDAC HQ, aptX HD, etc.)" // { default = true; };
    };

    disableLibcameraMonitor = lib.mkEnableOption "disable WirePlumber libcamera monitoring (useful if you only use v4l2loopback/OBS virtual cam)" // { default = true; };
  };

  config = lib.mkIf cfg.enable {
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;

      wireplumber = {
        enable = true;
        extraConfig = lib.mkMerge [
          (lib.mkIf cfg.disableLibcameraMonitor {
            "10-disable-camera" = {
              "wireplumber.profiles" = {
                main = {
                  "monitor.libcamera" = "disabled";
                };
              };
            };
          })
          (lib.mkIf cfg.bluetooth.highQualityCodecs {
            "20-bluetooth-high-quality" = {
              "bluez_monitor.properties" = {
                # Enable as many high-quality codecs as possible (hardware will negotiate what it supports)
                "bluez5.codecs" = [ "sbc" "sbc_xq" "aac" "ldac" "aptx" "aptx_hd" "aptx_ll" "faststream" ];
                "bluez5.enable-sbc-xq" = true;
                "bluez5.enable-msbc" = true;
                "bluez5.enable-hw-volume" = true;
                "bluez5.a2dp.ldac.quality" = "hq";  # Highest quality LDAC when available
              };
            };
          })
        ];
      };

      # Low-latency configuration (balanced default)
      extraConfig = lib.mkMerge [
        (lib.mkIf cfg.lowLatency.enable {
          pipewire."92-low-latency" = {
            "context.properties" = {
              "default.clock.rate" = 48000;
              "default.clock.quantum" = 1024;     # ~21 ms – good balance for gaming/streaming
              "default.clock.min-quantum" = if cfg.lowLatency.proAudio then 64 else 256;
              "default.clock.max-quantum" = 4096;
            };
          };

          pipewire-pulse."92-low-latency" = {
            "context.modules" = [{
              name = "libpipewire-module-protocol-pulse";
              args = {
                "pulse.min.req"       = "${toString (if cfg.lowLatency.proAudio then 64 else 256)}/48000";
                "pulse.default.req"   = "1024/48000";
                "pulse.max.req"       = "4096/48000";
                "pulse.min.quantum"   = "${toString (if cfg.lowLatency.proAudio then 64 else 256)}/48000";
                "pulse.max.quantum"   = "4096/48000";
              };
            }];
            "stream.properties" = {
              "node.latency"      = "1024/48000";
              "resample.quality"  = 10;  # Higher quality resampling (default is ~4)
            };
          };
        })
      ];
    };

    # Realtime scheduling (required for low-latency PipeWire)
    security.rtkit.enable = true;

    # Optional DE/WM-adaptive packages
    # - Always include core audio tools
    # - Add tray applets only when not using Plasma (Plasma has its own built-in volume widget)
    # - Hyprland users typically use pavucontrol or Waybar modules
    environment.systemPackages = with pkgs; [
      pavucontrol      # GUI mixer (works everywhere)
      easyeffects      # RNNoise, EQ, compressor, etc.
      qpwgraph         # PipeWire patchbay (already in your config)
      helvum           # Alternative nice patchbay
    ] ++ lib.optionals (!config.services.desktopManager.plasma6.enable) [
      pasystray        # System tray volume icon for non-Plasma sessions
    ];
  };
}
