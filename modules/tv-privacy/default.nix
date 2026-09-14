{ lib, ... }:

{
  options.custom.tvPrivacy = {
    enable = lib.mkEnableOption "Theater face: CEC/stream/LAN identifier hygiene plus local EDID store hygiene";
  };
}
