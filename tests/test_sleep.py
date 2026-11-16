#!/usr/bin/env python3

"""Unit tests for main-zone sleep timer XML. No sockets, no receiver I/O."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SESSION_PATH = Path(__file__).resolve().parents[1] / "yamaha-avr-session.py"


def load_session_module():
    spec = importlib.util.spec_from_file_location("yamaha_avr_session", SESSION_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {SESSION_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = load_session_module()


class SleepXmlTests(unittest.TestCase):
    def test_allowed_labels(self) -> None:
        expected = {
            "Off": "<Main_Zone><Power_Control><Sleep>Off</Sleep></Power_Control></Main_Zone>",
            "30 min": "<Main_Zone><Power_Control><Sleep>30 min</Sleep></Power_Control></Main_Zone>",
            "60 min": "<Main_Zone><Power_Control><Sleep>60 min</Sleep></Power_Control></Main_Zone>",
            "90 min": "<Main_Zone><Power_Control><Sleep>90 min</Sleep></Power_Control></Main_Zone>",
            "120 min": "<Main_Zone><Power_Control><Sleep>120 min</Sleep></Power_Control></Main_Zone>",
        }
        for value, xml in expected.items():
            with self.subTest(value=value):
                self.assertEqual(mod.sleep_control_xml(value), xml)
                self.assertEqual(mod.normalize_sleep(value), value)

    def test_aliases(self) -> None:
        self.assertEqual(mod.normalize_sleep("off"), "Off")
        self.assertEqual(mod.normalize_sleep("30"), "30 min")
        self.assertEqual(mod.normalize_sleep("sleep-60"), "60 min")
        self.assertEqual(mod.normalize_sleep("90min"), "90 min")
        self.assertEqual(mod.normalize_sleep("120-min"), "120 min")

    def test_invalid_value(self) -> None:
        with self.assertRaises(ValueError):
            mod.sleep_control_xml("15 min")
        with self.assertRaises(ValueError):
            mod.normalize_sleep("")

    def test_apply_sleep_does_not_post(self) -> None:
        with patch.object(mod, "safe_load_state", return_value={}):
            session = mod.YamahaSession("", "Test")
        with patch.object(session, "post", side_effect=AssertionError("post() must not run in tests")):
            inner = session.apply_sleep("30 min")
        self.assertEqual(
            inner,
            "<Main_Zone><Power_Control><Sleep>30 min</Sleep></Power_Control></Main_Zone>",
        )
        self.assertEqual(session.sleep, "30 min")

    def test_dispatch_sleep_posts_helper_xml_without_socket(self) -> None:
        with patch.object(mod, "safe_load_state", return_value={}):
            session = mod.YamahaSession("", "Test")
        posted: list[tuple[str, str]] = []

        def fake_post(cmd: str, inner: str):
            posted.append((cmd, inner))
            return None

        with patch.object(session, "post", side_effect=fake_post), patch.object(session, "refresh"):
            session.dispatch("sleep-90")

        self.assertEqual(posted, [("PUT", mod.sleep_control_xml("90 min"))])
        self.assertEqual(session.sleep, "90 min")

    def test_dispatch_sleep_off_posts_off_xml(self) -> None:
        with patch.object(mod, "safe_load_state", return_value={}):
            session = mod.YamahaSession("", "Test")
        session.sleep = "30 min"
        posted: list[tuple[str, str]] = []

        def fake_post(cmd: str, inner: str):
            posted.append((cmd, inner))
            return None

        with patch.object(session, "post", side_effect=fake_post), patch.object(session, "refresh"):
            session.dispatch("sleep-off")

        self.assertEqual(posted, [("PUT", mod.sleep_control_xml("Off"))])
        self.assertEqual(session.sleep, "Off")

    def test_dispatch_sleep_keeps_previous_value_if_post_fails(self) -> None:
        with patch.object(mod, "safe_load_state", return_value={}):
            session = mod.YamahaSession("", "Test")
        session.sleep = "Off"
        with patch.object(session, "post", side_effect=RuntimeError("network down")):
            with self.assertRaises(RuntimeError):
                session.dispatch("sleep-30")
        self.assertEqual(session.sleep, "Off")

    def test_refresh_reads_sleep_from_basic_status_without_socket(self) -> None:
        xml = (
            b'<?xml version="1.0" encoding="utf-8"?>'
            b'<YAMAHA_AV rsp="GET" RC="0"><Main_Zone><Basic_Status>'
            b"<Power_Control><Power>On</Power><Sleep>60 min</Sleep></Power_Control>"
            b"<Volume><Lvl><Val>-500</Val><Exp>1</Exp><Unit>dB</Unit></Lvl>"
            b"<Mute>Off</Mute></Volume>"
            b"</Basic_Status></Main_Zone></YAMAHA_AV>"
        )
        root = mod.safe_parse_xml(xml)
        with patch.object(mod, "safe_load_state", return_value={}):
            session = mod.YamahaSession("", "Test")
        session.model = "RX-V677"
        with patch.object(session, "post", return_value=root) as mocked, patch.object(
            session, "read_speaker_levels", return_value={}
        ), patch.object(session, "save_state"):
            session.refresh()
        mocked.assert_called_once_with(
            "GET", "<Main_Zone><Basic_Status>GetParam</Basic_Status></Main_Zone>"
        )
        self.assertEqual(session.sleep, "60 min")


if __name__ == "__main__":
    unittest.main()
