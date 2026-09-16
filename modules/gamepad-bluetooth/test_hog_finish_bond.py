#!/usr/bin/env python3
"""Unit tests for hog_finish_bond.classify. No D-Bus, no bluetoothctl."""

import unittest

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


if __name__ == "__main__":
    unittest.main()
