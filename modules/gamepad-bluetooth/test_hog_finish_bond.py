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


if __name__ == "__main__":
    unittest.main()
