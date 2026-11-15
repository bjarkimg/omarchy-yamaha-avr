#!/usr/bin/env python3
"""Allowlist for YNCA input names. No receiver connection."""

import importlib.util
import unittest
from pathlib import Path


def load_session():
    path = Path(__file__).with_name("yamaha-avr-session.py")
    spec = importlib.util.spec_from_file_location("yamaha_avr_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SESSION = load_session()


class InputSelectionTest(unittest.TestCase):
    def test_av_and_hdmi(self):
        self.assertEqual(SESSION.input_selection("av1"), "AV1")
        self.assertEqual(SESSION.input_selection("AV6"), "AV6")
        self.assertEqual(SESSION.input_selection("hdmi3"), "HDMI3")

    def test_aliases(self):
        self.assertEqual(SESSION.input_selection("appletv"), "AV4")
        self.assertEqual(SESSION.input_selection("vaux"), "V-AUX")
        self.assertEqual(SESSION.input_selection("net"), "NET RADIO")
        self.assertEqual(SESSION.input_selection("airplay"), "AirPlay")

    def test_rejects_unknown_and_markup(self):
        self.assertIsNone(SESSION.input_selection("av7"))
        self.assertIsNone(SESSION.input_selection("AV1</Input_Sel>"))
        self.assertIsNone(SESSION.input_selection("../USB"))
        self.assertIsNone(SESSION.input_selection(""))


if __name__ == "__main__":
    unittest.main()
