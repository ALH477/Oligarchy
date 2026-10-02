# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 DeMoD LLC.
"""distroinstall, driven without Calamares.

A fake `libcalamares` stands in for the host application (global storage, job
configuration, progress, logging, host_env_process_output). The upstream
`nixos` job is the REAL calamares-nixos-extensions main.py ($UPSTREAM_JOB): the
helpers distroinstall borrows from it (fix_btrfs_subvolumes, NixProgress,
generateProxyStrings) are exercised as shipped, so an upstream rename fails
here instead of at install time. External commands (pkexec,
nixos-generate-config, nixos-install) are shell stubs on PATH that record
their arguments.

  UPSTREAM_JOB=/nix/store/...-calamares-nixos-extensions-*/lib/calamares/modules/nixos/main.py \
    python3 -m unittest -v installer/calamares/tests/test_distroinstall.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
JOB = os.path.join(HERE, "..", "distroinstall", "main.py")
UPSTREAM = os.environ.get("UPSTREAM_JOB")


class GS:
    def __init__(self, values):
        self.values = values

    def value(self, key):
        return self.values.get(key)


def fake_libcalamares(gs, conf, log):
    lc = types.ModuleType("libcalamares")
    lc.globalstorage = GS(gs)
    lc.job = types.SimpleNamespace(configuration=conf, setprogress=lambda f: log.append(("progress", f)))

    def host_env_process_output(cmd, _cb, stdin=None):
        log.append(("host", list(cmd)))
        subprocess.run(cmd, input=None if stdin is None else stdin.encode(), check=True)
        return 0

    lc.utils = types.SimpleNamespace(
        gettext_path=lambda: "/nonexistent",
        gettext_languages=lambda: ["en"],
        debug=lambda m: log.append(("debug", m)),
        warning=lambda m: log.append(("warning", m)),
        error=lambda m: log.append(("error", m)),
        host_env_process_output=host_env_process_output,
    )
    return lc


def load_job(gs, conf, log):
    sys.modules["libcalamares"] = fake_libcalamares(gs, conf, log)
    spec = importlib.util.spec_from_file_location("distroinstall_under_test", JOB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def stub(bindir, name, body):
    path = os.path.join(bindir, name)
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)


EFI_GS = {
    "firmwareType": "efi",
    "bootLoader": {"installPath": "/dev/nvme0n1"},
    "partitions": [
        {"mountPoint": "/boot", "fs": "fat32", "fsName": "fat32", "claimed": True, "device": "/dev/nvme0n1p1"},
        {"mountPoint": "/", "fs": "ext4", "fsName": "ext4", "claimed": True, "device": "/dev/nvme0n1p2"},
    ],
    "hostname": "surface",
    "locationRegion": "Europe",
    "locationZone": "Berlin",
    "localeConf": {"LANG": "de_DE.UTF-8/UTF-8", "LC_TIME": "en_GB.UTF-8/UTF-8"},
    "keyboardLayout": "de",
    "keyboardVariant": "nodeadkeys",
    "username": "asher",
    "fullname": "Asher",
    "packagechooser_profile": "companion",
}

BIOS_LUKS_GS = {
    "firmwareType": "bios",
    "bootLoader": {"installPath": "/dev/sda"},
    "partitions": [
        {"mountPoint": "/", "fs": "ext4", "fsName": "luks2", "claimed": True, "device": "/dev/sda1",
         "luksMapperName": "luks-root", "uuid": "1111", "luksPassphrase": "pw"},
        {"mountPoint": "", "fs": "linuxswap", "fsName": "luks2", "claimed": True, "device": "/dev/sda2",
         "luksMapperName": "luks-swap", "uuid": "2222", "luksPassphrase": "pw"},
    ],
    "username": "asher",
    "autoLoginUser": "asher",
}

CONF = {
    "distro": "TestOS",
    "flakeAttr": "installed",
    "hostDir": "hosts/installed",
    "profileKey": "packagechooser_profile",
    "defaultProfile": "audio",
    "plainProfile": "plain",
    "profiles": ["audio", "companion"],
}


@unittest.skipUnless(UPSTREAM and os.path.exists(UPSTREAM), "set UPSTREAM_JOB to calamares-nixos-extensions' nixos/main.py")
class Collect(unittest.TestCase):
    def job(self, gs):
        return load_job(gs, dict(CONF, upstreamJob=UPSTREAM), [])

    def test_efi_install_json(self):
        data = self.job(EFI_GS).collect(GS(EFI_GS), "companion")
        self.assertEqual(data["profile"], "companion")
        self.assertEqual(data["hostname"], "surface")
        self.assertEqual(data["timeZone"], "Europe/Berlin")
        self.assertEqual(data["locale"], {"LANG": "de_DE.UTF-8", "LC_TIME": "en_GB.UTF-8"})
        self.assertEqual(data["keyboard"], {"layout": "de", "variant": "nodeadkeys", "consoleKeyMap": None})
        self.assertEqual(data["user"], {"name": "asher", "fullName": "Asher", "autologin": False})
        self.assertEqual(data["boot"], {"firmware": "efi", "device": "/dev/nvme0n1",
                                        "btrfsRoot": False, "grubCryptodisk": False})
        self.assertEqual(data["luks"], {"swap": [], "keyFile": []})

    def test_bios_encrypted_root_needs_cryptodisk_and_a_keyfile(self):
        data = self.job(BIOS_LUKS_GS).collect(GS(BIOS_LUKS_GS), "audio")
        self.assertEqual(data["boot"]["firmware"], "bios")
        self.assertEqual(data["boot"]["device"], "/dev/sda")
        self.assertTrue(data["boot"]["grubCryptodisk"])
        self.assertEqual(data["luks"]["keyFile"], ["luks-root", "luks-swap"])
        # Encrypted swap is invisible to nixos-generate-config; it must be here.
        self.assertEqual(data["luks"]["swap"], [{"name": "luks-swap", "uuid": "2222"}])
        self.assertTrue(data["user"]["autologin"])
        self.assertEqual(data["hostname"], "nixos")  # Calamares gave none

    def test_efi_encrypted_root_needs_no_keyfile(self):
        gs = dict(BIOS_LUKS_GS, firmwareType="efi")
        data = self.job(gs).collect(GS(gs), "audio")
        self.assertFalse(data["boot"]["grubCryptodisk"])
        self.assertEqual(data["luks"]["keyFile"], [])


@unittest.skipUnless(UPSTREAM and os.path.exists(UPSTREAM), "set UPSTREAM_JOB")
class Run(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.root = os.path.join(t, "mnt")
        os.makedirs(self.root)
        self.source = os.path.join(t, "source")
        os.makedirs(os.path.join(self.source, "modules"))
        with open(os.path.join(self.source, "flake.nix"), "w") as f:
            f.write("{ outputs = _: { }; }\n")
        with open(os.path.join(self.source, "modules", "x.nix"), "w") as f:
            f.write("{ }\n")
        os.chmod(os.path.join(self.source, "flake.nix"), 0o444)  # store copies are read-only
        self.bindir = os.path.join(t, "bin")
        os.makedirs(self.bindir)
        self.calls = os.path.join(t, "calls")
        stub(self.bindir, "pkexec", 'exec "$@"')
        stub(self.bindir, "nixos-generate-config",
             'echo "nixos-generate-config $*" >> ' + self.calls + '\n'
             'cat <<EOF\n{ fileSystems."/" = { device = "/dev/disk/by-uuid/x"; fsType = "btrfs"; '
             'options = [ "subvol=/" ]; };\n  fileSystems."/home" = { device = "/dev/disk/by-uuid/x"; '
             'fsType = "btrfs"; options = [ "subvol=/home" ]; }; }\nEOF')
        stub(self.bindir, "nixos-install",
             'echo "nixos-install $*" >> ' + self.calls + '\n'
             'echo \'@nix {"action":"msg","level":3,"msg":"installing"}\'\n'
             'exit ${FAKE_INSTALL_RC:-0}')
        self.oldpath = os.environ["PATH"]
        os.environ["PATH"] = self.bindir + ":" + self.oldpath
        self.log = []

    def tearDown(self):
        os.environ["PATH"] = self.oldpath
        os.environ.pop("FAKE_INSTALL_RC", None)
        self.tmp.cleanup()

    def run_job(self, gs):
        g = dict(gs, rootMountPoint=self.root)
        job = load_job(g, dict(CONF, source=self.source, upstreamJob=UPSTREAM), self.log)
        return job, job.run()

    def calls_text(self):
        if not os.path.exists(self.calls):
            return ""
        with open(self.calls) as f:
            return f.read()

    def test_profile_install_copies_the_flake_and_installs_it(self):
        g = dict(EFI_GS, partitions=[dict(p, fs="btrfs") if p["mountPoint"] == "/" else p
                                     for p in EFI_GS["partitions"]])
        job, result = self.run_job(g)
        self.assertIsNone(result, result)
        etc = os.path.join(self.root, "etc/nixos")
        self.assertTrue(os.path.exists(os.path.join(etc, "modules/x.nix")), "flake source not copied")
        self.assertTrue(os.access(os.path.join(etc, "flake.nix"), os.W_OK), "copied flake left read-only")
        hosts = os.path.join(etc, "hosts/installed")
        with open(os.path.join(hosts, "install.json")) as f:
            data = json.load(f)
        self.assertEqual(data, job.collect(job.libcalamares.globalstorage, "companion"))
        with open(os.path.join(hosts, "hardware-configuration.nix")) as f:
            hw = f.read()
        # Parity with upstream, not an outcome: the scan went through upstream's
        # own fix_btrfs_subvolumes where this upstream has one (nixos-25.11's
        # has none, and then the scan is written as it came). (Its regex,
        # `[^;]*` from fileSystems."/home" to "subvol=, cannot cross the
        # `device = "...";` nixos-generate-config writes first, so on real
        # scans it changes nothing. That is upstream's behaviour for plain
        # NixOS too, and this job keeps it.)
        scan = subprocess.check_output(["nixos-generate-config", "--root", self.root,
                                        "--show-hardware-config"]).decode()
        fix = getattr(job.upstream(), "fix_btrfs_subvolumes", None)
        self.assertEqual(hw, fix(scan, g["partitions"]) if fix else scan)
        self.assertIn('fileSystems."/home"', hw)
        calls = self.calls_text()
        self.assertIn("nixos-generate-config --root {} --show-hardware-config".format(self.root), calls)
        self.assertIn("--flake {}#installed".format(etc), calls)
        self.assertIn("--root {}".format(self.root), calls)
        self.assertIn("--no-root-passwd", calls)
        # internal-json only where upstream can parse it into progress.
        self.assertEqual("--log-format internal-json" in calls,
                         hasattr(job.upstream(), "NixProgress"))
        self.assertFalse(os.path.exists(os.path.join(etc, "configuration.nix")),
                         "a generic configuration.nix must not be left behind")

    def test_existing_etc_nixos_is_kept_aside(self):
        old = os.path.join(self.root, "etc/nixos")
        os.makedirs(old)
        with open(os.path.join(old, "configuration.nix"), "w") as f:
            f.write("# mine\n")
        _, result = self.run_job(EFI_GS)
        self.assertIsNone(result, result)
        kept = os.path.join(self.root, "etc/nixos.before-testos/configuration.nix")
        with open(kept) as f:
            self.assertEqual(f.read(), "# mine\n")

    def test_plain_hands_the_job_to_upstream_unmodified(self):
        g = dict(EFI_GS, packagechooser_profile="plain", rootMountPoint=self.root)
        job = load_job(g, dict(CONF, source=self.source, upstreamJob=UPSTREAM), self.log)
        called = []
        job.upstream().run = lambda: called.append(True) or None
        self.assertIsNone(job.run())
        self.assertEqual(called, [True])
        self.assertFalse(os.path.exists(os.path.join(self.root, "etc/nixos")), "plain must not copy the flake")
        self.assertEqual(self.calls_text(), "")

    def test_unknown_profile_is_refused_before_touching_the_disk(self):
        _, result = self.run_job(dict(EFI_GS, packagechooser_profile="gnome"))
        self.assertIsInstance(result, tuple)
        self.assertIn("gnome", result[1])
        self.assertFalse(os.path.exists(os.path.join(self.root, "etc")))

    def test_missing_choice_uses_the_default_profile(self):
        g = {k: v for k, v in EFI_GS.items() if k != "packagechooser_profile"}
        _, result = self.run_job(g)
        self.assertIsNone(result, result)
        with open(os.path.join(self.root, "etc/nixos/hosts/installed/install.json")) as f:
            data = json.load(f)
        self.assertEqual(data["profile"], "audio")

    def test_failed_install_is_reported_with_its_output(self):
        os.environ["FAKE_INSTALL_RC"] = "1"
        _, result = self.run_job(EFI_GS)
        self.assertIsInstance(result, tuple)
        self.assertIn("nixos-install", result[0])


if __name__ == "__main__":
    unittest.main()
