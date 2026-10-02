#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 DeMoD LLC.
"""<distro>-install -- the installer's job, from a shell instead of Calamares.

For the minimal ISO (no Calamares), and for scripted installs. It runs the
SAME job module the graphical installer runs (calamares/distroinstall/main.py)
with the answers taken from the command line, so the two cannot drift.

You partition, format and mount the target under --root first (the NixOS
manual's way), then:

  archibaldos-install --profile companion --user asher --hostname surface \\
      --timezone Europe/Berlin --locale en_US.UTF-8 --keyboard us

It copies the distribution's flake to <root>/etc/nixos, writes
hosts/installed/{hardware-configuration.nix,install.json}, runs
`nixos-install --flake <root>/etc/nixos#installed`, then asks for the new
user's password inside the new system (nixos-enter + passwd). Root gets no
password. --dry-run prints install.json and the nixos-install command and
touches nothing.

Not covered here (use the graphical installer): encrypted swap and BIOS GRUB
with an encrypted /boot. A LUKS root under UEFI works, because
nixos-generate-config records it.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))


class _GS:
    def __init__(self, values):
        self.values = values

    def value(self, key):
        return self.values.get(key)


def _libcalamares(gs, conf, dry_run):
    lc = types.ModuleType("libcalamares")
    lc.globalstorage = _GS(gs)
    last = {"pct": -1}

    def setprogress(f):
        pct = int(f * 100)
        if pct != last["pct"] and pct % 5 == 0:
            last["pct"] = pct
            print("  [{:3d}%]".format(pct), file=sys.stderr)

    lc.job = types.SimpleNamespace(configuration=conf, setprogress=setprogress)

    def host(cmd, _cb, stdin=None):
        if dry_run:
            print("would run: " + " ".join(cmd), file=sys.stderr)
            return 0
        subprocess.run(cmd, input=None if stdin is None else stdin.encode(), check=True)
        return 0

    lc.utils = types.SimpleNamespace(
        gettext_path=lambda: "/nonexistent",
        gettext_languages=lambda: ["en"],
        debug=lambda m: None,
        warning=lambda m: print("warning: " + m, file=sys.stderr),
        error=lambda m: print("error: " + m, file=sys.stderr),
        host_env_process_output=host,
    )
    return lc


def _load(path, name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv=None):
    conf = json.load(open(os.environ.get("DISTROINSTALL_CONF", os.path.join(HERE, "distroinstall.json"))))
    distro = conf["distro"]
    ap = argparse.ArgumentParser(prog=distro.lower() + "-install",
                                 description="Install {} onto filesystems mounted under --root.".format(distro))
    ap.add_argument("--profile", required=True, choices=conf["profiles"])
    ap.add_argument("--root", default="/mnt")
    ap.add_argument("--hostname", default="nixos")
    ap.add_argument("--user", required=True, help="the account to create")
    ap.add_argument("--full-name", default="")
    ap.add_argument("--timezone", help="IANA zone, e.g. Europe/Berlin")
    ap.add_argument("--locale", help="glibc locale, e.g. de_DE.UTF-8")
    ap.add_argument("--keyboard", help="xkb layout[:variant], e.g. de:nodeadkeys")
    ap.add_argument("--console-keymap", help="console keymap (default: derived from --keyboard)")
    ap.add_argument("--autologin", action="store_true")
    ap.add_argument("--boot-device", default=None,
                    help="BIOS only: the disk GRUB goes on (e.g. /dev/sda). UEFI is detected and needs none.")
    ap.add_argument("--no-passwd", action="store_true", help="do not prompt for the user's password afterwards")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)

    efi = os.path.isdir("/sys/firmware/efi")
    if not efi and not a.boot_device:
        ap.error("this machine booted without UEFI: say where GRUB goes with --boot-device /dev/sdX")
    if not a.dry_run and not os.path.ismount(a.root):
        ap.error("{} is not a mount point: partition, format and mount the target there first".format(a.root))
    if os.geteuid() != 0 and not a.dry_run:
        ap.error("run as root")

    gs = {
        "rootMountPoint": os.path.abspath(a.root),
        "firmwareType": "efi" if efi else "bios",
        "bootLoader": None if efi else {"installPath": a.boot_device},
        "partitions": [],
        "hostname": a.hostname,
        "username": a.user,
        "fullname": a.full_name,
        "autoLoginUser": a.user if a.autologin else None,
        "packagechooser_profile": a.profile,
    }
    if a.timezone:
        if "/" not in a.timezone:
            ap.error("--timezone must be Region/City")
        gs["locationRegion"], gs["locationZone"] = a.timezone.split("/", 1)
    if a.locale:
        gs["localeConf"] = {"LANG": a.locale}
    if a.keyboard:
        layout, _, variant = a.keyboard.partition(":")
        gs["keyboardLayout"], gs["keyboardVariant"] = layout, variant
        if a.console_keymap:
            gs["keyboardVConsoleKeymap"] = a.console_keymap

    sys.modules["libcalamares"] = _libcalamares(gs, conf, a.dry_run)
    job = _load(os.path.join(HERE, "calamares", "distroinstall", "main.py"), "distroinstall")

    if a.dry_run:
        print(json.dumps(job.collect(_GS(gs), a.profile), indent=2, sort_keys=True))
        print("would run: nixos-install --no-root-passwd --root {r} --flake {r}/etc/nixos#{attr}".format(
            r=gs["rootMountPoint"], attr=conf.get("flakeAttr", "installed")), file=sys.stderr)
        return 0

    # The job calls `pkexec` the way Calamares needs; we are already root.
    shim = tempfile.mkdtemp(prefix="distroinstall-")
    with open(os.path.join(shim, "pkexec"), "w") as f:
        f.write('#!/bin/sh\nexec "$@"\n')
    os.chmod(os.path.join(shim, "pkexec"), 0o755)
    os.environ["PATH"] = shim + ":" + os.environ.get("PATH", "")
    try:
        result = job.run()
    finally:
        shutil.rmtree(shim, ignore_errors=True)
    if result is not None:
        title, detail = result
        print("{}: {}\n{}".format(distro.lower() + "-install", title, detail), file=sys.stderr)
        return 1

    if not a.no_passwd:
        print("Set a password for {}:".format(a.user))
        subprocess.run(["nixos-enter", "--root", gs["rootMountPoint"], "-c", "passwd " + a.user], check=True)
    print("{} is installed. /etc/nixos on the new system is its flake; rebuild with\n"
          "  sudo nixos-rebuild switch --flake /etc/nixos#installed".format(distro))
    return 0


if __name__ == "__main__":
    sys.exit(main())
