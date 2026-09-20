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
        self.assertTrue(proc.stderr)
        self.assertIn("30", proc.stderr)

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
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), _quiet():
            hog_finish_bond.apply_commands([("pair", MAC)], dry_run=False)

        self.assertIn("trust", runner.verbs())
        self.assertEqual(runner.calls[-1], ["trust", MAC])

    def test_timed_out_pair_does_not_trust_when_still_unpaired(self):
        runner = _FakeRunner({"pair": (124, ""), "info": (0, XBOX_UNPAIRED)})
        with mock.patch.object(hog_finish_bond, "_run_bluetoothctl", runner), _quiet():
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


if __name__ == "__main__":
    unittest.main()
