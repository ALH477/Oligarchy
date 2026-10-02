# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 DeMoD LLC.
#
# calamares-nixos-extensions, extended so the installer installs THIS
# distribution instead of a generic configuration.nix:
#
#   - a `distroinstall` job (distroinstall/main.py) replaces `nixos` in the
#     exec sequence;
#   - a `packagechooser@profile` page replaces the desktop chooser and the
#     unfree-software page (the distribution decides both);
#   - "plain" stays on the profile list and runs the upstream `nixos` job
#     unmodified, so the ISO can still install plain NixOS.
#
# Nothing upstream is patched: upstream's files are copied as they are, and
# settings.conf is regenerated. The build REFUSES to proceed if upstream's
# own settings.conf no longer has the shape this file replaces (pages, jobs,
# instances), so an upstream change is noticed here and not at install time.
#
# Used through an overlay (installer/iso.nix): calamares-nixos wraps
# Calamares with XDG_CONFIG_DIRS/XDG_DATA_DIRS pointing at this package.
{ lib
, runCommand
, python3
, calamares-nixos-extensions
, distro                 # "ArchibaldOS"
, source                 # the distribution's flake source (a store path)
, profiles               # [ { id; name; description; } ], in display order
, defaultProfile
, flakeAttr ? "installed"
, hostDir ? "hosts/installed"
}:

let
  upstream = calamares-nixos-extensions;
  plain = {
    id = "plain";
    name = "Plain NixOS";
    description = ''
      A minimal NixOS with no desktop, installed by the stock NixOS job
      exactly as the upstream installer would. Nothing from ${distro}.
    '';
  };

  chooser = {
    mode = "required";
    method = "legacy";
    id = "profile"; # -> global storage `packagechooser_profile`
    labels.step = "Profile";
    default = defaultProfile;
    items = map (p: { inherit (p) id name; description = p.description; packages = [ ]; })
      (profiles ++ [ plain ]);
  };

  jobConf = {
    inherit distro flakeAttr hostDir defaultProfile;
    source = "${source}";
    profileKey = "packagechooser_profile";
    plainProfile = plain.id;
    profiles = map (p: p.id) profiles;
  };

  # What this file replaces in upstream's settings.conf. If upstream's
  # sequence or instances change, the build stops and says so. Two shapes are
  # known, both versioned 0.3.23: nixos-25.11's, and the later one that adds a
  # progress weight for the nixos job (nixos-unstable, mid-2026).
  expectedUpstream = {
    instances = [
      [{ id = "unfree"; module = "notesqml"; config = "unfree.conf"; }]
      [{ id = "unfree"; module = "notesqml"; config = "unfree.conf"; } { module = "nixos"; weight = 48; }]
    ];
    sequence = [
      { show = [ "welcome" "locale" "keyboard" "users" "packagechooser" "notesqml@unfree" "partition" "summary" ]; }
      { exec = [ "partition" "mount" "nixos" "users" "umount" ]; }
      { show = [ "finished" ]; }
    ];
  };

  settings = out: {
    "modules-search" = [ "local" "${out}/lib/calamares/modules" ];
    # Upstream's instances are kept as they are (an unused one is inert);
    # the profile page is added, and the install job gets the nixos job's
    # progress weight where upstream gives it one (see the build below).
    instances = [
      { id = "profile"; module = "packagechooser"; config = "packagechooser-profile.conf"; }
    ];
    sequence = [
      { show = [ "welcome" "locale" "keyboard" "users" "packagechooser@profile" "partition" "summary" ]; }
      { exec = [ "partition" "mount" "distroinstall" "users" "umount" ]; }
      { show = [ "finished" ]; }
    ];
  };

  py = python3.withPackages (ps: [ ps.pyyaml ]);
in
runCommand "calamares-${lib.toLower distro}-extensions-${upstream.version or "0"}"
{
  nativeBuildInputs = [ py ];
  expected = builtins.toJSON expectedUpstream;
  chooser = builtins.toJSON chooser;
  jobConf = builtins.toJSON jobConf;
  settings = builtins.toJSON (settings "@OUT@");
  passAsFile = [ "expected" "chooser" "jobConf" "settings" ];
  passthru = { inherit upstream distro profiles; };
}
  ''
    cp -r ${upstream} $out
    chmod -R u+w $out

    # Refuse to build on an upstream whose installer sequence moved.
    python3 - ${upstream}/etc/calamares/settings.conf "$expectedPath" <<'PY'
    import json, sys, yaml
    have = yaml.safe_load(open(sys.argv[1]))
    want = json.load(open(sys.argv[2]))
    for key, ok in (("instances", have.get("instances") in want["instances"]),
                    ("sequence", have.get("sequence") == want["sequence"])):
        if not ok:
            sys.exit("calamares-nixos-extensions changed its %s:\n  upstream: %r\n  expected: %r\n"
                     "Review installer/calamares/extensions.nix before shipping this installer."
                     % (key, have.get(key), want[key]))
    PY

    install -Dm0644 ${./distroinstall/main.py} $out/lib/calamares/modules/distroinstall/main.py
    install -Dm0644 ${./distroinstall/module.desc} $out/lib/calamares/modules/distroinstall/module.desc
    test -f $out/lib/calamares/modules/nixos/main.py   # "plain" delegates to it

    # JSON is YAML: Calamares reads these with yaml-cpp.
    install -Dm0644 "$chooserPath" $out/etc/calamares/modules/packagechooser-profile.conf
    install -Dm0644 "$jobConfPath" $out/etc/calamares/modules/distroinstall.conf
    rm $out/etc/calamares/settings.conf
    python3 - "$out" "$settingsPath" <<'PY'
    import json, sys, yaml
    out = sys.argv[1]
    have = yaml.safe_load(open("${upstream}/etc/calamares/settings.conf"))
    mine = json.loads(open(sys.argv[2]).read().replace("@OUT@", out))
    weights = [i for i in have["instances"] if i.get("module") == "nixos" and "weight" in i]
    mine["instances"] = have["instances"] + mine["instances"] + [
        {"module": "distroinstall", "weight": w["weight"]} for w in weights]
    have.update(mine)
    with open(out + "/etc/calamares/settings.conf", "w") as f:
        f.write("# Generated by installer/calamares/extensions.nix from upstream's settings.conf.\n")
        yaml.safe_dump(have, f, sort_keys=False)
    PY

    # The job must at least compile, against the interpreter Calamares uses.
    python3 -m py_compile $out/lib/calamares/modules/distroinstall/main.py
  ''
