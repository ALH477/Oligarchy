#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 DeMoD LLC.
"""distroinstall -- a Calamares job that installs a distribution's own flake.

The NixOS Calamares job (calamares-nixos-extensions, `nixos`) writes a generic
/etc/nixos/configuration.nix and runs `nixos-install`. On an ArchibaldOS or an
Oligarchy ISO that installs plain NixOS: the distribution the user booted is
not what lands on the disk. This job replaces it in the exec sequence:

  1. the chosen profile comes from the `packagechooser@profile` page;
  2. "plain" hands the whole job to the UNMODIFIED upstream `nixos` job,
     imported from the sibling module directory -- so a plain NixOS install
     is still exactly what it was, and nothing upstream is patched;
  3. any other profile: the distribution's flake source (baked into the ISO,
     the same revision the user booted) is copied to <root>/etc/nixos, the
     hardware scan goes to hosts/installed/hardware-configuration.nix, the
     user's choices go to hosts/installed/install.json, and
     `nixos-install --flake <root>/etc/nixos#installed` installs it.

The JSON is data, not Nix. The distribution maps it to its own options in Nix
(ArchibaldOS `installer/installed.nix`, Oligarchy `installer/installed.nix`),
where `nix flake check` can test the mapping against fixtures. This file only
collects and copies; `collect()` is a pure function of global storage so the
unit tests can drive it without Calamares.

Configuration (distroinstall.conf, YAML):
  distro, source, flakeAttr, hostDir, profileKey, defaultProfile,
  plainProfile, profiles (list of ids), upstreamJob (optional path).
"""
import gettext
import importlib.util
import json
import os
import subprocess

import libcalamares

_ = gettext.translation(
    "calamares-python",
    localedir=libcalamares.utils.gettext_path(),
    languages=libcalamares.utils.gettext_languages(),
    fallback=True,
).gettext

SCHEMA = 1
INSTALL_PROGRESS_START = 0.1
INSTALL_PROGRESS_END = 1.0

_upstream_module = None


class _NoProgress:
    """Stands in for upstream's NixProgress when upstream has none."""
    fraction = 0.0

    def __init__(self):
        self.log_messages = []

    def handle(self, line):
        return False


def _conf():
    return libcalamares.job.configuration or {}


def _distro():
    return _conf().get("distro", "NixOS")


def pretty_name():
    return _("Installing {}.").format(_distro())


status = pretty_name()


def pretty_status_message():
    return status


def upstream():
    """The unmodified upstream `nixos` job module, loaded from its own file."""
    global _upstream_module
    if _upstream_module is None:
        path = _conf().get("upstreamJob") or os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "nixos", "main.py"
        )
        spec = importlib.util.spec_from_file_location("calamares_nixos_upstream", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _upstream_module = mod
    return _upstream_module


# --------------------------------------------------------------------------
# collect(): global storage -> install.json. Pure; no I/O.
# --------------------------------------------------------------------------
def _first(value):
    """Calamares locale values look like "de_DE.UTF-8/UTF-8"; keep the name."""
    return None if value is None else str(value).split("/")[0]


def _is_luks(part):
    return part.get("fsName") in ("luks", "luks2")


def collect(gs, profile):
    """Everything the distribution needs from the installer, as plain data."""
    partitions = gs.value("partitions") or []
    fw = gs.value("firmwareType")
    bootloader = gs.value("bootLoader")
    device = "nodev" if bootloader is None else bootloader.get("installPath") or "nodev"

    root_is_btrfs = any(p.get("mountPoint") == "/" and p.get("fs") == "btrfs" for p in partitions)
    root = next((p for p in partitions if p.get("mountPoint") == "/"), None)
    boot = next((p for p in partitions if p.get("mountPoint") == "/boot"), None)
    root_encrypted = bool(root and _is_luks(root))
    boot_encrypted = bool(boot and _is_luks(boot))
    # Upstream's rule: under BIOS, GRUB must read an encrypted /boot itself
    # (cryptodisk), and the initrd then needs a keyfile so the passphrase is
    # asked for once, not twice.
    cryptodisk = fw != "efi" and ((boot is not None and boot_encrypted) or (boot is None and root_encrypted))

    claimed_luks = [p for p in partitions if p.get("claimed") is True and _is_luks(p) and p.get("device")]

    locale = None
    lc = gs.value("localeConf")
    if lc is not None:
        locale = {k: _first(v) for k, v in dict(lc).items() if v is not None}

    tz = None
    if gs.value("locationRegion") is not None and gs.value("locationZone") is not None:
        tz = "{}/{}".format(gs.value("locationRegion"), gs.value("locationZone"))

    keyboard = None
    if gs.value("keyboardLayout") is not None:
        keyboard = {
            "layout": gs.value("keyboardLayout"),
            "variant": gs.value("keyboardVariant") or "",
            "consoleKeyMap": (gs.value("keyboardVConsoleKeymap") or "").strip() or None,
        }

    user = None
    if gs.value("username") is not None:
        user = {
            "name": gs.value("username"),
            "fullName": gs.value("fullname") or "",
            "autologin": gs.value("autoLoginUser") is not None,
        }

    return {
        "schema": SCHEMA,
        "distro": _distro(),
        "profile": profile,
        "hostname": gs.value("hostname") or "nixos",
        "timeZone": tz,
        "locale": locale,
        "keyboard": keyboard,
        "user": user,
        "boot": {
            "firmware": "efi" if fw == "efi" else "bios",
            "device": device,
            "btrfsRoot": root_is_btrfs,
            "grubCryptodisk": cryptodisk,
        },
        "luks": {
            # nixos-generate-config does not see encrypted swap (upstream note).
            "swap": [
                {"name": p["luksMapperName"], "uuid": p["uuid"]}
                for p in claimed_luks
                if p.get("fs") == "linuxswap"
            ],
            "keyFile": [p["luksMapperName"] for p in claimed_luks] if cryptodisk else [],
        },
    }


# --------------------------------------------------------------------------
# run(): the job.
# --------------------------------------------------------------------------
def _host(cmd, stdin=None):
    return libcalamares.utils.host_env_process_output(cmd, None, stdin)


def _write(path, text):
    _host(["cp", "/dev/stdin", path], text)


def _luks_keyfile(root_mount_point, partitions, names):
    """Upstream's BIOS+cryptodisk keyfile: one passphrase prompt, in GRUB."""
    keyfile = root_mount_point + "/boot/crypto_keyfile.bin"
    _host(["mkdir", "-p", root_mount_point + "/boot"])
    _host(["chmod", "0700", root_mount_point + "/boot"])
    _host(["dd", "bs=512", "count=4", "if=/dev/random", "of=" + keyfile, "iflag=fullblock"])
    _host(["chmod", "600", keyfile])
    for part in partitions:
        if part.get("luksMapperName") not in names:
            continue
        # GRUB reads LUKS2 only with pbkdf2.
        _host(["cryptsetup", "luksConvertKey", "--hash", "sha256", "--pbkdf", "pbkdf2", part["device"]],
              part["luksPassphrase"])
        _host(["cryptsetup", "luksAddKey", "--hash", "sha256", "--pbkdf", "pbkdf2", part["device"], keyfile],
              part["luksPassphrase"])


def run():
    global status
    conf = _conf()
    gs = libcalamares.globalstorage

    profile = gs.value(conf.get("profileKey", "packagechooser_profile")) or conf.get("defaultProfile")
    if profile == conf.get("plainProfile", "plain"):
        # Plain NixOS: the upstream job, untouched, with its own config text.
        return upstream().run()
    if profile not in conf.get("profiles", []):
        return (_("Unknown profile"),
                _("{} has no installable profile '{}'.").format(_distro(), profile))

    source = conf["source"]
    root_mount_point = gs.value("rootMountPoint")
    etc = os.path.join(root_mount_point, "etc/nixos")
    host_dir = os.path.join(etc, conf.get("hostDir", "hosts/installed"))
    partitions = gs.value("partitions") or []

    status = _("Copying the {} flake").format(_distro())
    libcalamares.job.setprogress(0.01)
    data = collect(gs, profile)
    try:
        if os.path.isdir(etc) and os.listdir(etc):
            # A reused root that already had /etc/nixos: keep it, out of the way.
            _host(["mv", etc, etc + ".before-" + _distro().lower()])
        _host(["mkdir", "-p", etc])
        # The source is the store copy of the flake the ISO was built from.
        _host(["cp", "-rT", source, etc])
        _host(["chmod", "-R", "u+w", etc])
        _host(["mkdir", "-p", host_dir])
    except subprocess.CalledProcessError as e:
        return (_("Could not copy the {} flake").format(_distro()), str(e))

    if data["luks"]["keyFile"]:
        status = _("Setting up LUKS")
        libcalamares.job.setprogress(0.02)
        try:
            _luks_keyfile(root_mount_point, partitions, data["luks"]["keyFile"])
        except subprocess.CalledProcessError as e:
            return (_("cryptsetup failed"), str(e))

    status = _("Scanning hardware")
    libcalamares.job.setprogress(0.04)
    try:
        hw = subprocess.check_output(
            ["pkexec", "nixos-generate-config", "--root", root_mount_point, "--show-hardware-config"],
            stderr=subprocess.STDOUT,
        ).decode("utf8")
    except subprocess.CalledProcessError as e:
        out = e.output.decode("utf8") if e.output else str(e)
        libcalamares.utils.error(out)
        return (_("nixos-generate-config failed"), out)
    # Upstream's own fix, where this upstream has one (not nixos-25.11's).
    fix = getattr(upstream(), "fix_btrfs_subvolumes", None)
    if fix is not None:
        hw = fix(hw, partitions)
    _write(os.path.join(host_dir, "hardware-configuration.nix"), hw)
    _write(os.path.join(host_dir, "install.json"), json.dumps(data, indent=2, sort_keys=True) + "\n")

    status = _("Installing {}").format(_distro())
    libcalamares.job.setprogress(INSTALL_PROGRESS_START)
    try:
        subprocess.check_output(["pkexec", "chmod", "755", root_mount_point], stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as e:
        libcalamares.utils.warning("Failed to set permissions on {}: {}".format(root_mount_point, e.output))

    # Progress from nix's internal-json log, where upstream has the parser
    # (NixProgress; nixos-25.11's job has none, and then the bar holds still
    # and the log is plain text).
    progress_cls = getattr(upstream(), "NixProgress", None)
    progress = progress_cls() if progress_cls is not None else _NoProgress()
    cmd = ["pkexec"] + upstream().generateProxyStrings() + [
        "nixos-install",
        "--no-root-passwd",
        "--root", root_mount_point,
        "--flake", "{}#{}".format(etc, conf.get("flakeAttr", "installed")),
    ] + (["--log-format", "internal-json"] if progress_cls is not None else []) + [
        # Same reason as upstream: the chroot store's default build dir is
        # under /tmp, which Nix refuses (world-writable parent).
        "--option", "build-dir", "/nix/var/nix/builds",
    ]
    output = ""
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        while True:
            line = proc.stdout.readline().decode("utf-8")
            if not line:
                break
            if not progress.handle(line):
                output += line
                libcalamares.utils.debug("nixos-install: {}".format(line.strip()))
            for msg in progress.log_messages:
                output += msg + "\n"
                libcalamares.utils.debug("nixos-install: {}".format(msg))
            progress.log_messages.clear()
            libcalamares.job.setprogress(
                INSTALL_PROGRESS_START + progress.fraction * (INSTALL_PROGRESS_END - INSTALL_PROGRESS_START))
        proc.stdout.close()
        if proc.wait() != 0:
            return (_("nixos-install failed"), output[-4000:])
    except OSError as e:
        return (_("nixos-install failed"), str(e))

    libcalamares.job.setprogress(INSTALL_PROGRESS_END)
    return None
