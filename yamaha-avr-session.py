#!/usr/bin/env python3

"""YNCA session backend for Yamaha network AV receivers (RX-V677 and similar)."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


TIMEOUT = 4
SPEAKER_LEVEL_MIN = -100
SPEAKER_LEVEL_MAX = 100
LR_PAIRS = (
    ("Front_L", "Front_R"),
    ("Sur_L", "Sur_R"),
    ("Sur_Back_L", "Sur_Back_R"),
    ("Front_Presence_L", "Front_Presence_R"),
)


def emit(event: str, **values: Any) -> None:
    print(json.dumps({"event": event, **values}, separators=(",", ":")), flush=True)


def ynca_xml(cmd: str, inner: str) -> str:
    return f'<?xml version="1.0" encoding="utf-8"?><YAMAHA_AV cmd="{cmd}">{inner}</YAMAHA_AV>'


class YamahaSession:
    def __init__(self, host: str, name: str) -> None:
        self.host = host.strip()
        self.name = name.strip() or "Yamaha AVR"
        self.model = "Yamaha AVR"
        self.connected = False
        self.power = ""
        self.mute = ""
        self.input_sel = ""
        self.volume_db: float | None = None
        self.program = ""
        self.straight = "Off"
        self.enhancer = "Off"
        self.pure_direct = "Off"
        self.cinema_3d = "Off"
        self.dialogue_lift = 0
        self.dialogue_lvl = 0
        self.lr_balance = 0
        self.speaker_levels: dict[str, int] = {}
        self.seat_baseline: dict[str, int] = {}
        state_home = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state")))
        self.state_path = state_home / "omarchy" / "settings" / "yamaha-avr.json"
        self.load_state()

    def load_state(self) -> None:
        try:
            loaded = json.loads(self.state_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return
        if isinstance(loaded, dict):
            self.host = str(loaded.get("host") or self.host)
            self.name = str(loaded.get("name") or self.name)
            baseline = loaded.get("seatBaseline")
            if isinstance(baseline, dict):
                parsed: dict[str, int] = {}
                for key, value in baseline.items():
                    if re.fullmatch(r"-?\d+", str(value)):
                        parsed[str(key)] = int(value)
                self.seat_baseline = parsed

    def save_state(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "host": self.host,
            "name": self.name,
            "model": self.model,
            "seatBaseline": self.seat_baseline,
        }
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        tmp.chmod(0o600)
        os.replace(tmp, self.state_path)

    def url(self) -> str:
        return f"http://{self.host}/YamahaRemoteControl/ctrl"

    def post(self, cmd: str, inner: str) -> ET.Element:
        data = ynca_xml(cmd, inner).encode("utf-8")
        request = urllib.request.Request(
            self.url(),
            data=data,
            method="POST",
            headers={"Content-Type": "text/xml; charset=UTF-8"},
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                body = response.read()
        except urllib.error.URLError as error:
            self.connected = False
            raise RuntimeError(f"could not reach {self.name} at {self.host}") from error
        root = ET.fromstring(body)
        rc = root.attrib.get("RC", "")
        if rc not in {"", "0"}:
            raise RuntimeError(f"receiver rejected command (RC={rc})")
        self.connected = True
        return root

    def refresh(self) -> None:
        root = self.post("GET", "<Main_Zone><Basic_Status>GetParam</Basic_Status></Main_Zone>")
        power = root.findtext(".//Power_Control/Power")
        mute = root.findtext(".//Volume/Mute")
        input_sel = root.findtext(".//Input/Input_Sel")
        program = root.findtext(".//Sound_Program")
        val = root.findtext(".//Volume/Lvl/Val")
        exp = root.findtext(".//Volume/Lvl/Exp") or "1"
        self.power = power or ""
        self.mute = mute or ""
        self.input_sel = input_sel or ""
        self.program = program or ""
        self.straight = root.findtext(".//Straight") or self.straight
        self.enhancer = root.findtext(".//Enhancer") or self.enhancer
        self.pure_direct = root.findtext(".//Pure_Direct/Mode") or self.pure_direct
        self.cinema_3d = root.findtext(".//_3D_Cinema_DSP") or self.cinema_3d
        lift = root.findtext(".//Dialogue_Lift")
        level = root.findtext(".//Dialogue_Lvl")
        if lift is not None and re.fullmatch(r"-?\d+", lift):
            self.dialogue_lift = max(0, min(5, int(lift)))
        if level is not None and re.fullmatch(r"-?\d+", level):
            self.dialogue_lvl = max(0, min(3, int(level)))
        if val is not None and re.fullmatch(r"-?\d+", val):
            self.volume_db = int(val) / (10 ** int(exp or "1"))
        else:
            self.volume_db = None
        self._refresh_speaker_levels()
        try:
            cfg = self.post("GET", "<System><Config>GetParam</Config></System>")
            self.model = cfg.findtext(".//Model_Name") or self.model
            net = self.post(
                "GET",
                "<System><Misc><Network><Network_Name>GetParam</Network_Name></Network></Misc></System>",
            )
            self.name = net.findtext(".//Network_Name") or self.name
        except Exception:
            pass
        self.save_state()

    def status_payload(self) -> dict[str, Any]:
        awake = self.power.lower() == "on"
        return {
            "name": self.name,
            "host": self.host,
            "model": self.model,
            "power": self.power,
            "mute": self.mute,
            "input": self.input_sel,
            "program": self.program,
            "straight": self.straight,
            "enhancer": self.enhancer,
            "pureDirect": self.pure_direct,
            "cinema3d": self.cinema_3d,
            "dialogueLift": self.dialogue_lift,
            "dialogueLvl": self.dialogue_lvl,
            "lrBalance": self.lr_balance,
            "volumeDb": self.volume_db,
            "status": "awake" if awake else "standby",
        }

    def put_main(self, inner: str) -> None:
        self.post("PUT", f"<Main_Zone>{inner}</Main_Zone>")
        self.refresh()

    def _channel_tenths(self, channel: str, source: dict[str, int] | None = None) -> int | None:
        levels = self.speaker_levels if source is None else source
        value = levels.get(channel)
        if value is None:
            return None
        return max(SPEAKER_LEVEL_MIN, min(SPEAKER_LEVEL_MAX, int(value)))

    def _refresh_speaker_levels(self) -> None:
        try:
            root = self.post(
                "GET",
                "<System><Speaker_Preout><Pattern_1><Lvl>GetParam</Lvl></Pattern_1></Speaker_Preout></System>",
            )
        except Exception:
            return
        levels: dict[str, int] = {}
        lvl = root.find(".//Lvl")
        if lvl is None:
            return
        for child in list(lvl):
            val = child.findtext("Val")
            if val is not None and re.fullmatch(r"-?\d+", val):
                levels[child.tag] = int(val)
        if not levels:
            return
        self.speaker_levels = levels
        if not self.seat_baseline:
            self.seat_baseline = dict(levels)
            self.save_state()
        self.lr_balance = self._tilt_from_levels()

    def _tilt_from_levels(self) -> int:
        left = self._channel_tenths("Front_L")
        right = self._channel_tenths("Front_R")
        base_left = self._channel_tenths("Front_L", self.seat_baseline)
        base_right = self._channel_tenths("Front_R", self.seat_baseline)
        if None in {left, right, base_left, base_right}:
            return self.lr_balance
        delta = ((right - base_right) - (left - base_left)) / 20.0
        return max(-5, min(5, int(round(delta))))

    def _lvl_xml(self, channel: str, tenths: int) -> str:
        tenths = max(SPEAKER_LEVEL_MIN, min(SPEAKER_LEVEL_MAX, tenths))
        return (
            f"<{channel}><Val>{tenths}</Val><Exp>1</Exp><Unit>dB</Unit></{channel}>"
        )

    def _put_speaker_levels(self, levels: dict[str, int]) -> None:
        inner = "".join(self._lvl_xml(name, value) for name, value in levels.items())
        self.post(
            "PUT",
            f"<System><Speaker_Preout><Pattern_1><Lvl>{inner}</Lvl></Pattern_1></Speaker_Preout></System>",
        )

    def _set_lr_balance(self, tilt: int) -> None:
        tilt = max(-5, min(5, int(tilt)))
        if not self.speaker_levels:
            self._refresh_speaker_levels()
        if not self.seat_baseline and self.speaker_levels:
            self.seat_baseline = dict(self.speaker_levels)
            self.save_state()
        if not self.seat_baseline:
            raise RuntimeError("could not read speaker levels")
        next_levels: dict[str, int] = {}
        delta = tilt * 10
        for left_ch, right_ch in LR_PAIRS:
            base_left = self._channel_tenths(left_ch, self.seat_baseline)
            base_right = self._channel_tenths(right_ch, self.seat_baseline)
            if base_left is not None:
                next_levels[left_ch] = base_left - delta
            if base_right is not None:
                next_levels[right_ch] = base_right + delta
        if not next_levels:
            raise RuntimeError("no left/right speakers to tilt")
        self._put_speaker_levels(next_levels)
        self.lr_balance = tilt

    def _set_dialogue_lift(self, n: int) -> None:
        n = max(0, min(5, int(n)))
        self.put_main(
            f"<Sound_Video><Dialogue_Adjust><Dialogue_Lift>{n}</Dialogue_Lift></Dialogue_Adjust></Sound_Video>"
        )

    def _nudge_volume(self, delta_tenths: int) -> None:
        """RX-V677 rejects Val=Up/Down. Set an absolute tenth-dB value instead."""
        if self.volume_db is None:
            self.refresh()
        if self.volume_db is None:
            raise RuntimeError("could not read volume")
        current = int(round(self.volume_db * 10))
        nxt = max(-805, min(165, current + delta_tenths))
        self.put_main(
            f"<Volume><Lvl><Val>{nxt}</Val><Exp>1</Exp><Unit>dB</Unit></Lvl></Volume>"
        )

    def dispatch(self, action: str) -> dict[str, Any]:
        if action == "status":
            self.refresh()
            return self.status_payload()
        if action == "power":
            nxt = "Standby" if self.power.lower() == "on" else "On"
            if not self.power:
                self.refresh()
                nxt = "Standby" if self.power.lower() == "on" else "On"
            self.put_main(f"<Power_Control><Power>{nxt}</Power></Power_Control>")
            return self.status_payload()
        if action in {"power-on", "wake"}:
            self.put_main("<Power_Control><Power>On</Power></Power_Control>")
            return self.status_payload()
        if action in {"power-off", "sleep"}:
            self.put_main("<Power_Control><Power>Standby</Power></Power_Control>")
            return self.status_payload()
        if action == "mute":
            nxt = "Off" if self.mute.lower() == "on" else "On"
            self.put_main(f"<Volume><Mute>{nxt}</Mute></Volume>")
            return self.status_payload()
        if action == "volume-up":
            self._nudge_volume(+10)
            return self.status_payload()
        if action == "volume-down":
            self._nudge_volume(-10)
            return self.status_payload()
        if action.startswith("input-"):
            mapping = {
                "input-hdmi1": "HDMI1",
                "input-hdmi2": "HDMI2",
                "input-hdmi3": "HDMI3",
                "input-hdmi4": "HDMI4",
                "input-hdmi5": "HDMI5",
                "input-av1": "AV1",
                "input-audio1": "AUDIO1",
                "input-tuner": "TUNER",
                "input-airplay": "AirPlay",
            }
            if action not in mapping:
                raise ValueError(f"unknown input: {action}")
            self.put_main(f"<Input><Input_Sel>{mapping[action]}</Input_Sel></Input>")
            return self.status_payload()
        if action == "straight":
            nxt = "Off" if self.straight.lower() == "on" else "On"
            self.put_main(
                "<Surround><Program_Sel><Current>"
                f"<Straight>{nxt}</Straight>"
                "</Current></Program_Sel></Surround>"
            )
            return self.status_payload()
        if action == "pure-direct":
            nxt = "Off" if self.pure_direct.lower() == "on" else "On"
            self.put_main(f"<Sound_Video><Pure_Direct><Mode>{nxt}</Mode></Pure_Direct></Sound_Video>")
            return self.status_payload()
        if action == "program-7ch":
            self.put_main(
                "<Surround><Program_Sel><Current>"
                "<Straight>Off</Straight>"
                "<Sound_Program>7ch Stereo</Sound_Program>"
                "</Current></Program_Sel></Surround>"
            )
            return self.status_payload()
        if action == "program-2ch":
            self.put_main(
                "<Surround><Program_Sel><Current>"
                "<Straight>Off</Straight>"
                "<Sound_Program>2ch Stereo</Sound_Program>"
                "</Current></Program_Sel></Surround>"
            )
            return self.status_payload()
        if action == "program-decoder":
            self.put_main(
                "<Surround><Program_Sel><Current>"
                "<Straight>Off</Straight>"
                "<Sound_Program>Surround Decoder</Sound_Program>"
                "</Current></Program_Sel></Surround>"
            )
            return self.status_payload()
        if action.startswith("lift-"):
            try:
                n = max(0, min(5, int(action.split("-", 1)[1])))
            except ValueError as error:
                raise ValueError(f"unknown lift: {action}") from error
            self.put_main(
                f"<Sound_Video><Dialogue_Adjust><Dialogue_Lift>{n}</Dialogue_Lift></Dialogue_Adjust></Sound_Video>"
            )
            return self.status_payload()
        if action.startswith("scene-"):
            mapping = {
                "scene-1": "Scene 1",
                "scene-2": "Scene 2",
                "scene-3": "Scene 3",
                "scene-4": "Scene 4",
            }
            if action not in mapping:
                raise ValueError(f"unknown scene: {action}")
            self.put_main(f"<Scene><Scene_Sel>{mapping[action]}</Scene_Sel></Scene>")
            return self.status_payload()
        raise ValueError(f"unknown action: {action}")

    def handle_request(self, request: dict[str, Any]) -> None:
        operation = str(request.get("op", ""))
        if operation == "lift":
            try:
                n = max(0, min(5, int(request.get("value", 0))))
            except (TypeError, ValueError) as error:
                raise RuntimeError("lift must be 0-5") from error
            self.put_main(
                f"<Sound_Video><Dialogue_Adjust><Dialogue_Lift>{n}</Dialogue_Lift></Dialogue_Adjust></Sound_Video>"
            )
            emit("result", action="lift", result=str(n), **self.status_payload())
            return
        if operation in {"seat", "balance"}:
            try:
                x = max(-5, min(5, int(request.get("x", request.get("value", self.lr_balance)))))
            except (TypeError, ValueError) as error:
                raise RuntimeError("left/right must be -5 to 5") from error
            y = self.dialogue_lift
            if "y" in request:
                try:
                    y = max(0, min(5, int(request.get("y", 0))))
                except (TypeError, ValueError) as error:
                    raise RuntimeError("lift must be 0-5") from error
            if "y" in request:
                self.post(
                    "PUT",
                    "<Main_Zone><Sound_Video><Dialogue_Adjust>"
                    f"<Dialogue_Lift>{y}</Dialogue_Lift>"
                    "</Dialogue_Adjust></Sound_Video></Main_Zone>",
                )
            self._set_lr_balance(x)
            self.refresh()
            emit("result", action=operation, result=f"{x},{y}", **self.status_payload())
            return
        if operation == "set-host":
            host = str(request.get("host", "")).strip()
            if not host:
                raise RuntimeError("enter a host IP")
            self.host = host
            if request.get("name"):
                self.name = str(request["name"]).strip()
            self.refresh()
            self.save_state()
            emit("switched", **self.status_payload())
            return
        raise ValueError(f"unknown operation: {operation}")

    def run(self) -> None:
        try:
            self.refresh()
            emit("ready", **self.status_payload())
        except Exception as error:
            emit("error", action="connect", message=str(error), connected=False)

        while True:
            line = sys.stdin.readline()
            if not line:
                break
            raw = line.strip()
            if not raw or raw == "quit":
                if raw == "quit":
                    break
                continue
            started = time.monotonic()
            try:
                if raw.startswith("{"):
                    self.handle_request(json.loads(raw))
                    continue
                result = self.dispatch(raw)
                emit(
                    "result",
                    action=raw,
                    result=result.get("status", ""),
                    elapsedMs=round((time.monotonic() - started) * 1000, 1),
                    **result,
                )
            except Exception as error:
                emit("error", action=raw[:24], message=str(error), connected=self.connected)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="")
    parser.add_argument("--name", default="Yamaha AVR")
    args = parser.parse_args()
    YamahaSession(args.host, args.name).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
