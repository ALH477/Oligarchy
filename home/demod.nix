args@{
  config,
  pkgs,
  lib,
  inputs,
  username ? "asher",
  features ? {},
  theme ? "demod",
  ...
}:

import ./home.nix args
