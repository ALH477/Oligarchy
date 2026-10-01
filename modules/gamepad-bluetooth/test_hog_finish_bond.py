#!/usr/bin/env python3
"""Unit tests for hog_finish_bond. No D-Bus, no bluetoothctl."""

import contextlib
import io
import subprocess
import unittest
from unittest import mock

import hog_finish_bond
from hog_finish_bond import Action, classify


XBOX_UNPAIRED = """\
Device 78:86:2E:BA:73:6E (public)
	Name: Xbox Wireless Controller
	Alias: Xbox Wireless Controller
	Appearance: 0x03c4 (964)
	Icon: input-gaming
	Paired: no
	Bonded: no
	Trusted: yes
	Blocked: no
	Connected: yes
	UUID: Generic Access Profile    (00001800-0000-1000-8000-00805f9b34fb)
	UUID: Human Interface Device    (00001812-0000-1000-8000-00805f9b34fb)
	ManufacturerData.Key: 0x0006 (6)
	LE.Paired: no
	LE.Bonded: no
	LE.Connected: yes
"""

XBOX_PAIRED = """\
Device 78:86:2E:BA:73:6E (public)
	Name: Xbox Wireless Controller
	Appearance: 0x03c4 (964)
	Paired: yes
	Bonded: yes
	Trusted: yes
	Blocked: no
	Connected: yes
	UUID: Human Interface Device    (00001812-0000-1000-8000-00805f9b34fb)
	LE.Paired: yes
	LE.Bonded: yes
	LE.Connected: yes
"""

XBOX_PAIRED_UNTRUSTED = """\
Device 78:86:2E:BA:73:6E (public)
	Appearance: 0x03c4 (964)
	Paired: yes
	Bonded: yes
	Trusted: no
	Blocked: no
	Connected: yes
	UUID: Human Interface Device    (00001812-0000-1000-8000-00805f9b34fb)
"""

KEYBOARD_UNPAIRED = """\
Device AA:BB:CC:DD:EE:FF (public)
	Name: Xbox Wireless Controller
	Appearance: 0x03c1 (961)
	Icon: input-keyboard
	Paired: no
	Bonded: no
	Trusted: no
	Blocked: no
	Connected: yes
	UUID: Human Interface Device    (00001812-0000-1000-8000-00805f9b34fb)
"""

HEADPHONES = """\
Device 94:DB:56:84:B4:FE (public)
	Name: LE_WH-1000XM3
	Paired: yes
	Bonded: yes
	Trusted: yes
	Blocked: no
	Connected: yes
	UUID: Audio Sink                (0000110b-0000-1000-8000-00805f9b34fb)
"""

HID_NO_APPEARANCE = """\
Device 00:11:22:33:44:55 (public)
	Name: Mystery HID
	Paired: no
	Bonded: no
	Trusted: no
	Blocked: no
	Connected: yes
	UUID: Human Interface Device    (00001812-0000-1000-8000-00805f9b34fb)
"""

GAMEPAD_DISCONNECTED = """\
Device 78:86:2E:BA:73:6E (public)
	Appearance: 0x03c4 (964)
	Paired: no
	Bonded: no
	Trusted: no
	Blocked: no
	Connected: no
	UUID: Human Interface Device    (00001812-0000-1000-8000-00805f9b34fb)
"""

BLOCKED_GAMEPAD = """\
Device 78:86:2E:BA:73:6E (public)
	Appearance: 0x03c4 (964)
	Paired: no
	Bonded: no
	Trusted: no
	Blocked: yes
	Connected: yes
	UUID: Human Interface Device    (00001812-0000-1000-8000-00805f9b34fb)
"""


class ClassifyTests(unittest.TestCase):
    def test_xbox_connected_unpaired_pairs(self):
        self.assertEqual(classify(XBOX_UNPAIRED), Action.PAIR)

    def test_xbox_already_paired_noop(self):
        self.assertEqual(classify(XBOX_PAIRED), Action.NOOP)

    def test_xbox_paired_untrusted_trusts_only(self):
        self.assertEqual(classify(XBOX_PAIRED_UNTRUSTED), Action.TRUST)

    def test_keyboard_even_named_xbox_is_ignored(self):
        self.assertEqual(classify(KEYBOARD_UNPAIRED), Action.NOOP)

    def test_headphones_ignored(self):
        self.assertEqual(classify(HEADPHONES), Action.NOOP)

    def test_hid_without_gamepad_appearance_ignored(self):
        self.assertEqual(classify(HID_NO_APPEARANCE), Action.NOOP)

    def test_disconnected_gamepad_ignored(self):
        self.assertEqual(classify(GAMEPAD_DISCONNECTED), Action.NOOP)

    def test_blocked_gamepad_ignored(self):
        self.assertEqual(classify(BLOCKED_GAMEPAD), Action.NOOP)


class RunnerTests(unittest.TestCase):
    def test_dry_run_pair_then_not_trust_unpaired(self):
        from hog_finish_bond import plan_commands

        cmds = plan_commands({"78:86:2E:BA:73:6E": XBOX_UNPAIRED})
        self.assertEqual(cmds, [("pair", "78:86:2E:BA:73:6E")])

    def test_dry_run_trust_only_when_paired(self):
        from hog_finish_bond import plan_commands

        cmds = plan_commands({"78:86:2E:BA:73:6E": XBOX_PAIRED_UNTRUSTED})
        self.assertEqual(cmds, [("trust", "78:86:2E:BA:73:6E")])

    def test_dry_run_keyboard_emits_nothing(self):
        from hog_finish_bond import plan_commands

        cmds = plan_commands({"AA:BB:CC:DD:EE:FF": KEYBOARD_UNPAIRED})
        self.assertEqual(cmds, [])

    def test_reconnect_needed_when_paired_connected_but_no_js(self):
        from hog_finish_bond import plan_reconnect

        self.assertEqual(
            plan_reconnect(paired=True, connected=True, js_exists=False),
            [("disconnect",), ("connect",)],
        )

    def test_no_reconnect_when_js_exists(self):
        from hog_finish_bond import plan_reconnect

        self.assertEqual(
            plan_reconnect(paired=True, connected=True, js_exists=True),
            [],
        )

    def test_reconnect_argv_is_one_disconnect_one_connect(self):
        from hog_finish_bond import plan_reconnect, reconnect_bt_args

        steps = plan_reconnect(paired=True, connected=True, js_exists=False)
        self.assertEqual(
            reconnect_bt_args("78:86:2E:BA:73:6E", steps),
            [
                ["disconnect", "78:86:2E:BA:73:6E"],
                ["connect", "78:86:2E:BA:73:6E"],
            ],
        )

    def test_trust_after_pair_requires_paired_flag(self):
        from hog_finish_bond import should_trust_after_pair

        self.assertFalse(should_trust_after_pair(XBOX_UNPAIRED))
        self.assertTrue(should_trust_after_pair(XBOX_PAIRED))
        self.assertTrue(should_trust_after_pair(XBOX_PAIRED_UNTRUSTED))

    def test_hog_input_bound_is_per_mac_not_any_js(self):
        from hog_finish_bond import hog_input_bound

        other_js = """\
I: Bus=0003 Vendor=044f Product=b10a Version=0111
N: Name="T.Flight Hotas"
H: Handlers=event21 js0
B: KEY=0
"""
        xbox = """\
I: Bus=0005 Vendor=045e Product=0b13 Version=0509
N: Name="Xbox Wireless Controller"
U: Uniq=78:86:2e:ba:73:6e
H: Handlers=kbd event20 js1
B: KEY=7fff000000000000 0 8000000000 0 0
"""
        self.assertFalse(hog_input_bound("78:86:2E:BA:73:6E", other_js))
        self.assertTrue(hog_input_bound("78:86:2E:BA:73:6E", other_js + "\n\n" + xbox))


MAC = "78:86:2E:BA:73:6E"


@contextlib.contextmanager
def _quiet():
    """Swallow the module's operator chatter so test output stays readable."""
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        yield


class _FakeRunner:
    """Stand-in for _run_bluetoothctl: records argv, replies per verb."""

    def __init__(self, replies):
        self.replies = replies
        self.calls = []

    def __call__(self, args, *, timeout=20):
        args = list(args)
        self.calls.append(args)
        rc, out = self.replies.get(args[0], (0, ""))
        return subprocess.CompletedProcess(
            args=["bluetoothctl", *args], returncode=rc, stdout=out, stderr=""
        )

    def verbs(self):
        return [a[0] for a in self.calls]


class TimeoutTests(unittest.TestCase):
    def test_run_bluetoothctl_converts_timeout_into_rc124(self):
        def boom(*a, **kw):
            raise subprocess.TimeoutExpired(cmd=["bluetoothctl", "pair", MAC], timeout=30)

        with mock.patch.object(hog_finish_bond.subprocess, "run", side_effect=boom):
            proc = hog_finish_bond._run_bluetoothctl(["pair", MAC], timeout=30)

        self.assertEqual(proc.returncode, 124)
        self.assertEqual(proc.stdout, "")
        self.assertEqual(proc.stderr, "timed out after 30s")

    def test_timeout_keeps_the_childs_own_stderr(self):
        def boom(*a, **kw):
            raise subprocess.TimeoutExpired(
                cmd=["bluetoothctl", "pair", MAC],
                timeout=30,
                stderr=b"Failed to pair: org.bluez.Error.AuthenticationCanceled",
            )

        with mock.patch.object(hog_finish_bond.subprocess, "run", side_effect=boom):
            proc = hog_finish_bond._run_bluetoothctl(["pair", MAC], timeout=30)

        self.assertEqual(proc.returncode, 124)
        self.assertIn("Failed to pair: org.bluez.Error.AuthenticationCanceled", proc.stderr)
        self.assertIn("timed out after", proc.stderr)

    def test_run_bluetoothctl_decodes_bytes_stdout_from_timeout(self):
        def boom(*a, **kw):
            raise subprocess.TimeoutExpired(
                cmd=["bluetoothctl", "pair", MAC], timeout=30, output=b"partial\n"
            )

        with mock.patch.object(hog_finish_bond.subprocess, "run", side_effect=boom):
            proc = hog_finish_bond._run_bluetoothctl(["pair", MAC], timeout=30)

        self.assertEqual(proc.returncode, 124)
        self.assertEqual(proc.stdout, "partial\n")


class ApplyCommandsTests(unittest.TestCase):
    def test_timed_out_pair_still_trusts_when_bluez_finished_the_bond(self):
        runner = _FakeRunner({"pair": (124, ""), "info": (0, XBOX_PAIRED)})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), _quiet():
            hog_finish_bond.apply_commands([("pair", MAC)], dry_run=False)

        self.assertIn("trust", runner.verbs())
        self.assertEqual(runner.calls[-1], ["trust", MAC])

    def test_timed_out_pair_does_not_trust_when_still_unpaired(self):
        runner = _FakeRunner({"pair": (124, ""), "info": (0, XBOX_UNPAIRED)})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), _quiet():
            hog_finish_bond.apply_commands([("pair", MAC)], dry_run=False)

        self.assertNotIn("trust", runner.verbs())
        self.assertIn("info", runner.verbs())

    def test_failed_trust_does_not_re_read_info(self):
        runner = _FakeRunner({"trust": (1, ""), "info": (0, XBOX_PAIRED)})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), _quiet():
            hog_finish_bond.apply_commands([("trust", MAC)], dry_run=False)

        self.assertEqual(runner.verbs(), ["trust"])

    def test_dry_run_runs_no_bluetoothctl_at_all(self):
        runner = _FakeRunner({})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), _quiet():
            hog_finish_bond.apply_commands([("pair", MAC)], dry_run=True)

        self.assertEqual(runner.calls, [])

    def test_wait_until_paired_polls_until_paired_yes(self):
        replies = [
            (0, XBOX_UNPAIRED),
            (0, XBOX_UNPAIRED),
            (0, XBOX_PAIRED),
        ]

        def flip(args, *, timeout=10):
            rc, out = replies.pop(0)
            return subprocess.CompletedProcess(
                args=["bluetoothctl", *args], returncode=rc, stdout=out, stderr=""
            )

        sleeps = []
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", flip), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda s: sleeps.append(s)):
            info = hog_finish_bond.wait_until_paired(MAC, attempts=6, delay=2.0)

        self.assertTrue(hog_finish_bond.should_trust_after_pair(info))
        self.assertEqual(sleeps, [2.0, 2.0])
        self.assertEqual(replies, [])

    def test_wait_until_paired_gives_up_still_unpaired(self):
        runner = _FakeRunner({"info": (0, XBOX_UNPAIRED)})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None):
            info = hog_finish_bond.wait_until_paired(MAC, attempts=3, delay=2.0)

        self.assertFalse(hog_finish_bond.should_trust_after_pair(info))
        self.assertEqual(runner.verbs(), ["info", "info", "info"])

    def test_timed_out_pair_trusts_after_delayed_paired_yes(self):
        infos = [XBOX_UNPAIRED, XBOX_PAIRED]

        class Runner(_FakeRunner):
            def __call__(self, args, *, timeout=20):
                args = list(args)
                self.calls.append(args)
                if args[0] == "pair":
                    return subprocess.CompletedProcess(
                        args=["bluetoothctl", *args], returncode=124, stdout="", stderr=""
                    )
                if args[0] == "info":
                    out = infos.pop(0)
                    return subprocess.CompletedProcess(
                        args=["bluetoothctl", *args], returncode=0, stdout=out, stderr=""
                    )
                if args[0] == "trust":
                    return subprocess.CompletedProcess(
                        args=["bluetoothctl", *args], returncode=0, stdout="", stderr=""
                    )
                return subprocess.CompletedProcess(
                    args=["bluetoothctl", *args], returncode=0, stdout="", stderr=""
                )

        runner = Runner({})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), _quiet():
            hog_finish_bond.apply_commands([("pair", MAC)], dry_run=False)

        self.assertIn("trust", runner.verbs())


class MaybeReconnectTests(unittest.TestCase):
    def test_empty_info_does_not_fire_blind_disconnect_connect(self):
        runner = _FakeRunner({"info": (124, "")})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), _quiet():
            hog_finish_bond.maybe_reconnect(MAC, dry_run=False)

        self.assertEqual(runner.verbs(), ["info"])

    def test_paired_connected_without_js_reconnects(self):
        runner = _FakeRunner({"info": (0, XBOX_PAIRED)})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), \
                mock.patch.object(hog_finish_bond, "hog_input_bound", lambda *_: False), _quiet():
            hog_finish_bond.maybe_reconnect(MAC, dry_run=False)

        self.assertEqual(runner.verbs(), ["info", "disconnect", "connect"])

    def test_dry_run_skips_the_info_call(self):
        runner = _FakeRunner({})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond, "hog_input_bound", lambda *_: False), _quiet():
            hog_finish_bond.maybe_reconnect(MAC, dry_run=True)

        self.assertEqual(runner.calls, [])


MAC2 = "AA:BB:CC:DD:EE:FF"


class _ScriptedRunner:
    """Replies per (verb, arg) so two `info` calls can differ. Records argv."""

    def __init__(self, replies):
        self.replies = replies
        self.calls = []

    def __call__(self, args, *, timeout=10):
        args = list(args)
        self.calls.append(args)
        key = tuple(args)
        rc, out, err = self.replies.get(key, self.replies.get((args[0],), (0, "", "")))
        return subprocess.CompletedProcess(
            args=["bluetoothctl", *args], returncode=rc, stdout=out, stderr=err
        )


class CollectInfosTests(unittest.TestCase):
    def test_devices_call_is_filtered_to_connected(self):
        runner = _ScriptedRunner({("devices", "Connected"): (0, "", "")})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), _quiet():
            hog_finish_bond.collect_infos()

        self.assertEqual(runner.calls[0], ["devices", "Connected"])

    def test_failed_devices_call_raises_instead_of_inspecting_nothing(self):
        runner = _ScriptedRunner(
            {("devices", "Connected"): (124, "", "timed out after 10s")}
        )
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), _quiet():
            with self.assertRaises(hog_finish_bond.CollectError):
                hog_finish_bond.collect_infos()

        self.assertEqual(runner.calls, [["devices", "Connected"]])

    def test_main_returns_1_when_it_could_not_list_devices(self):
        runner = _ScriptedRunner(
            {("devices", "Connected"): (124, "", "timed out after 10s")}
        )
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), _quiet():
            self.assertEqual(hog_finish_bond.main([]), 1)

    def test_failed_info_skips_that_mac_without_poisoning_the_map(self):
        listing = f"Device {MAC} Xbox Wireless Controller\nDevice {MAC2} Mystery\n"
        runner = _ScriptedRunner(
            {
                ("devices", "Connected"): (0, listing, ""),
                ("info", MAC): (0, XBOX_UNPAIRED, ""),
                ("info", MAC2): (1, "", "Device AA:BB:CC:DD:EE:FF not available"),
            }
        )
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), _quiet():
            infos = hog_finish_bond.collect_infos()

        self.assertEqual(list(infos), [MAC])
        self.assertEqual(infos[MAC], XBOX_UNPAIRED)

    def test_collect_retries_until_a_connected_unpaired_pad_appears(self):
        listing = f"Device {MAC} Xbox Wireless Controller\n"
        empty = _ScriptedRunner({("devices", "Connected"): (0, "", "")})
        later = _ScriptedRunner(
            {
                ("devices", "Connected"): (0, listing, ""),
                ("info", MAC): (0, XBOX_UNPAIRED, ""),
            }
        )
        calls = {"n": 0}

        def flip(args, *, timeout=10):
            calls["n"] += 1
            if calls["n"] == 1:
                return empty(args, timeout=timeout)
            return later(args, timeout=timeout)

        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", flip), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), _quiet():
            infos = hog_finish_bond.collect_infos_until_action(tries=5, delay=1.0)

        self.assertEqual(list(infos), [MAC])
        self.assertEqual(hog_finish_bond.classify(infos[MAC]), Action.PAIR)
        self.assertGreaterEqual(calls["n"], 2)

    def test_collect_retries_raises_if_every_listing_fails(self):
        runner = _ScriptedRunner(
            {("devices", "Connected"): (124, "", "timed out after 10s")}
        )
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), _quiet():
            with self.assertRaises(hog_finish_bond.CollectError):
                hog_finish_bond.collect_infos_until_action(tries=3, delay=1.0)

        self.assertEqual(len(runner.calls), 3)

    def test_main_retries_then_pairs(self):
        listing = f"Device {MAC} Xbox Wireless Controller\n"
        n = {"i": 0}

        def flip(args, *, timeout=10):
            args = list(args)
            n["i"] += 1
            if args[:2] == ["devices", "Connected"] and n["i"] == 1:
                return subprocess.CompletedProcess(
                    args=["bluetoothctl", *args], returncode=0, stdout="", stderr=""
                )
            replies = {
                ("devices", "Connected"): (0, listing, ""),
                ("info", MAC): (0, XBOX_UNPAIRED, ""),
                ("pair", MAC): (0, "", ""),
                ("trust", MAC): (0, "", ""),
            }
            key = tuple(args)
            rc, out, err = replies.get(key, (0, "", ""))
            return subprocess.CompletedProcess(
                args=["bluetoothctl", *args], returncode=rc, stdout=out, stderr=err
            )

        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", flip), \
                mock.patch.object(hog_finish_bond.time, "sleep", lambda *_: None), \
                mock.patch.object(hog_finish_bond, "hog_input_bound", lambda *_: True), \
                _quiet():
            self.assertEqual(hog_finish_bond.main([]), 0)


PROC_INPUT_SAMPLE = """\
I: Bus=0019 Vendor=0000 Product=0005 Version=0000
N: Name="Lid Switch"
P: Phys=PNP0C0D/button/input0
S: Sysfs=/devices/LNXSYSTM:00/button/input3
U: Uniq=
H: Handlers=event3
B: PROP=0

I: Bus=0005 Vendor=045e Product=028e Version=1130
N: Name="Xbox Wireless Controller"
P: Phys=fc:b0:de:17:f6:88
S: Sysfs=/devices/virtual/misc/uhid/0005:045E:0B13.0009/input/input24
U: Uniq=78:86:2e:ba:73:6e
H: Handlers=event24 js0
B: PROP=0

I: Bus=0003 Vendor=093a Product=0274 Version=0111
N: Name="PIXA3854:00 093A:0274 Touchpad"
P: Phys=i2c-PIXA3854:00
S: Sysfs=/devices/platform/AMDI0010:03/input/input14
U: Uniq=
H: Handlers=event12 mouse1
B: PROP=5
"""


class GamepadEventNodeTests(unittest.TestCase):
    def test_finds_only_the_joystick_block(self):
        self.assertEqual(
            hog_finish_bond.gamepad_event_nodes(PROC_INPUT_SAMPLE), ["event24"]
        )

    def test_a_pad_under_any_name_is_still_found(self):
        # Same reason classify() ignores names: the name proves nothing. A pad
        # reporting a vendor alias must not be missed.
        renamed = PROC_INPUT_SAMPLE.replace(
            'N: Name="Xbox Wireless Controller"', 'N: Name="Generic BT Gamepad"'
        )
        self.assertEqual(hog_finish_bond.gamepad_event_nodes(renamed), ["event24"])

    def test_a_device_named_xbox_without_a_js_handler_is_ignored(self):
        # Mirrors test_keyboard_even_named_xbox_is_ignored: an "Xbox" keyboard
        # has no js handler and must not be reported as a pad.
        decoy = PROC_INPUT_SAMPLE.replace("H: Handlers=event24 js0", "H: Handlers=event24 kbd")
        self.assertEqual(hog_finish_bond.gamepad_event_nodes(decoy), [])

    def test_empty_input(self):
        self.assertEqual(hog_finish_bond.gamepad_event_nodes(""), [])


class XpadneoRuleFileTests(unittest.TestCase):
    def test_finds_both_upstream_rules(self):
        listing = {
            "/etc/udev/rules.d": [
                "60-steam-input.rules",
                "60-xpadneo.rules",
                "70-xpadneo-disable-hidraw.rules",
                "99-local.rules",
            ],
        }
        self.assertEqual(
            hog_finish_bond.xpadneo_rule_files(lambda d: listing.get(d, [])),
            [
                "/etc/udev/rules.d/60-xpadneo.rules",
                "/etc/udev/rules.d/70-xpadneo-disable-hidraw.rules",
            ],
        )

    def test_missing_rules_report_empty_not_an_exception(self):
        # The regression this whole diagnose path exists for: nixpkgs' xpadneo
        # installs the .ko alone, so this list came back empty on a system whose
        # kernel log looked perfect.
        listing = {"/etc/udev/rules.d": ["60-steam-input.rules", "99-local.rules"]}
        self.assertEqual(
            hog_finish_bond.xpadneo_rule_files(lambda d: listing.get(d, [])), []
        )

    def test_a_missing_directory_is_not_fatal(self):
        def lister(d):
            if d == "/etc/udev/rules.d":
                return ["60-xpadneo.rules"]
            raise AssertionError("absent dirs must be filtered by the caller")

        listing = {"/etc/udev/rules.d": ["60-xpadneo.rules"]}
        self.assertEqual(
            hog_finish_bond.xpadneo_rule_files(lambda d: listing.get(d, [])),
            ["/etc/udev/rules.d/60-xpadneo.rules"],
        )


class DiagnoseCommandTests(unittest.TestCase):
    def test_every_node_is_probed_for_access(self):
        cmds = hog_finish_bond.diagnose_commands(["event24"], ["hidraw8"])
        argvs = [argv for _, argv in cmds]
        self.assertIn(["getfacl", "/dev/input/event24"], argvs)
        self.assertIn(["getfacl", "/dev/hidraw8"], argvs)
        self.assertIn(
            ["udevadm", "info", "--query=all", "--name=/dev/input/event24"], argvs
        )

    def test_probes_are_read_only(self):
        # A diagnostic that can change state is not a diagnostic. No argv here
        # may carry a mutating verb.
        forbidden = {"pair", "trust", "remove", "connect", "disconnect", "block"}
        for _, argv in hog_finish_bond.diagnose_commands(["event1"], ["hidraw0"]):
            self.assertFalse(
                forbidden.intersection(argv),
                msg=f"mutating verb in diagnostic argv: {argv}",
            )

    def test_no_nodes_still_collects_the_log_and_bond_state(self):
        labels = [label for label, _ in hog_finish_bond.diagnose_commands([], [])]
        self.assertIn("xpadneo kernel log", labels)
        self.assertIn("bonded devices", labels)


class DiagnoseDispatchTests(unittest.TestCase):
    def test_diagnose_flag_routes_to_diagnose_and_never_pairs(self):
        called = {}

        def fake_diagnose():
            called["yes"] = True
            return 0

        with mock.patch.object(hog_finish_bond, "diagnose", fake_diagnose), \
                mock.patch.object(
                    hog_finish_bond, "collect_infos_until_action",
                    lambda *a, **k: (_ for _ in ()).throw(
                        AssertionError("--diagnose must not touch bonding")
                    ),
                ), _quiet():
            self.assertEqual(hog_finish_bond.main(["prog", "--diagnose"]), 0)
        self.assertTrue(called)

    def test_help_mentions_diagnose(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(hog_finish_bond.main(["prog", "--help"]), 0)
        self.assertIn("--diagnose", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
