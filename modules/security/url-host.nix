# hostOf: the bare hostname of a URL.
#
# Scheme-agnostic (splits on `//`), strips a `user:pass@` prefix and a `:port`
# suffix. Shared by the two producers of strict-egress domain allowlist
# entries — strict-egress.nix (nix.settings substituters) and
# captive-portal/default.nix (the login page) — so both agree on what a
# "domain" is: a `host:port` entry is a domain that never resolves, which is
# exactly what the captive-portal module used to emit for a loginUrl with a
# port. .#captive-portal-contract asserts the port is stripped end to end.
#
# Known gap, unchanged from the inline version this replaces: a bracketed
# IPv6 literal (`http://[::1]:8080/`) is split on its own colons.
{ lib }:
url:
let
  inherit (lib) head last splitString;
  afterScheme = last (splitString "//" url);
  hostPort = head (splitString "/" afterScheme);
in
head (splitString ":" (last (splitString "@" hostPort)))
