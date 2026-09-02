#!/usr/bin/env python3

"""YNCA session backend for Yamaha network AV receivers (RX-V677 and similar)."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import secrets
import socket
import stat
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
MAX_STATE_SIZE = 65536
MAX_XML_SIZE = 65536
MAX_STDIN_LINE = 65536
MAX_ELEMENTS = 500

LR_PAIRS = (
    ("Front_L", "Front_R"),
    ("Sur_L", "Sur_R"),
    ("Sur_Back_L", "Sur_Back_R"),
    ("Front_Presence_L", "Front_Presence_R"),
)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject any HTTP redirects to prevent SSRF pivoting."""

    def http_error_302(self, req: Any, fp: Any, code: int, msg: str, headers: Any) -> Any:
        raise urllib.error.HTTPError(
            req.full_url, code, "HTTP redirects are disabled for receiver communication", headers, fp
        )

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


def emit(event: str, **values: Any) -> None:
    print(json.dumps({"event": event, **values}, separators=(",", ":")), flush=True)


def ynca_xml(cmd: str, inner: str) -> str:
    return f'<?xml version="1.0" encoding="utf-8"?><YAMAHA_AV cmd="{cmd}">{inner}</YAMAHA_AV>'


def resolve_and_validate_lan_ip(host: str) -> str:
    """Resolve host and strictly enforce private RFC 1918 IPv4 LAN boundary."""
    clean_host = host.strip().split(":")[0]
    if not clean_host:
        raise ValueError("Host is required")

    try:
        addr_info = socket.getaddrinfo(clean_host, None, family=socket.AF_INET, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        raise ValueError(f"Could not resolve host '{clean_host}': {error}") from error

    if not addr_info:
        raise ValueError(f"No IPv4 address found for host '{clean_host}'")

    ip_str = addr_info[0][4][0]
    try:
        ip = ipaddress.IPv4Address(ip_str)
    except ipaddress.AddressValueError as error:
        raise ValueError(f"Invalid IP address '{ip_str}': {error}") from error

    if not ip.is_private:
        raise ValueError(f"Address {ip} is not a private LAN IP (must be RFC 1918)")
    if ip.is_loopback:
        raise ValueError(f"Address {ip} is loopback (not permitted)")
    if ip.is_link_local:
        raise ValueError(f"Address {ip} is link-local (not permitted)")
    if ip.is_multicast:
        raise ValueError(f"Address {ip} is multicast (not permitted)")
    if ip.is_reserved:
        raise ValueError(f"Address {ip} is reserved (not permitted)")

    return ip_str


def get_secure_settings_dir() -> Path:
    state_home = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state")))
    settings_dir = state_home / "omarchy" / "settings"
    os.makedirs(settings_dir, mode=0o700, exist_ok=True)
    return settings_dir


def safe_load_state(filename: str = "yamaha-avr.json") -> dict[str, Any]:
    """Read state with descriptor-bound directory access and size checks."""
    settings_dir = get_secure_settings_dir()
    dir_fd = -1
    fd = -1
    try:
        dir_fd = os.open(str(settings_dir), os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
        except FileNotFoundError:
            return {}

        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return {}
        if st.st_uid != os.getuid():
            return {}
        if st.st_size > MAX_STATE_SIZE:
            return {}

        content = os.read(fd, MAX_STATE_SIZE).decode("utf-8", errors="replace")
        data = json.loads(content)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}
    finally:
        if fd >= 0:
            os.close(fd)
        if dir_fd >= 0:
            os.close(dir_fd)


def safe_save_state(payload: dict[str, Any], filename: str = "yamaha-avr.json") -> None:
    """Atomically write state using exclusive temporary creation, fsync, and rename."""
    settings_dir = get_secure_settings_dir()
    encoded = (json.dumps(payload, indent=2) + "\n").encode("utf-8")
    if len(encoded) > MAX_STATE_SIZE:
        raise ValueError("State payload exceeds maximum size")

    tmp_name = f"{filename}.{os.getpid()}.{secrets.token_hex(4)}.tmp"
    tmp_path = settings_dir / tmp_name
    target_path = settings_dir / filename
    dir_fd = -1
    tmp_fd = -1
    try:
        dir_fd = os.open(str(settings_dir), os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        tmp_fd = os.open(
            tmp_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=dir_fd,
        )
        st = os.fstat(tmp_fd)
        if st.st_uid != os.getuid():
            raise PermissionError("Directory owner mismatch")
        os.write(tmp_fd, encoded)
        os.fsync(tmp_fd)
        os.close(tmp_fd)
        tmp_fd = -1
        os.replace(tmp_path, target_path)
    finally:
        if tmp_fd >= 0:
            os.close(tmp_fd)
        if dir_fd >= 0:
            os.close(dir_fd)
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass


def safe_parse_xml(xml_bytes: bytes) -> ET.Element:
    """Parse XML with disabled entity expansion and max element limits."""
    if len(xml_bytes) > MAX_XML_SIZE:
        raise ValueError(f"XML payload too large ({len(xml_bytes)} bytes > {MAX_XML_SIZE})")

    parser = ET.XMLParser()
    parser.entity = {}
    root = ET.fromstring(xml_bytes, parser=parser)

    element_count = sum(1 for _ in root.iter())
    if element_count > MAX_ELEMENTS:
        raise ValueError(f"XML structure contains too many elements ({element_count} > {MAX_ELEMENTS})")

    return root


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
        self.load_state()

    def load_state(self) -> None:
        loaded = safe_load_state()
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
        payload = {
            "host": self.host,
            "name": self.name,
            "model": self.model,
            "seatBaseline": self.seat_baseline,
        }
        safe_save_state(payload)

    def post(self, cmd: str, inner: str) -> ET.Element:
        if not self.host:
            raise ValueError("No receiver host configured")

        validated_ip = resolve_and_validate_lan_ip(self.host)
        data = ynca_xml(cmd, inner).encode("utf-8")
        if len(data) > MAX_XML_SIZE:
            raise ValueError("XML request exceeded maximum size")

        url = f"http://{validated_ip}/YamahaRemoteControl/ctrl"
        request = urllib.request.Request(
            url,
            data=data,
            method="POST",
            headers={
                "Content-Type": "text/xml; charset=UTF-8",
                "Host": self.host,
            },
        )
        opener = urllib.request.build_opener(NoRedirectHandler())
        try:
            with opener.open(request, timeout=TIMEOUT) as response:
                body = response.read(MAX_XML_SIZE + 1)
                if len(body) > MAX_XML_SIZE:
                    raise ValueError("Receiver response exceeded maximum allowed size")
        except urllib.error.URLError as error:
            self.connected = False
            raise RuntimeError(f"Could not reach {self.name} at {self.host}") from error

        root = safe_parse_xml(body)
        rc = root.attrib.get("RC", "")
        if rc not in {"", "0"}:
            raise RuntimeError(f"Receiver rejected command (RC={rc})")
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

        if self.model == "Yamaha AVR":
            try:
                sys_root = self.post("GET", "<System><Config>GetParam</Config></System>")
                model = sys_root.findtext(".//Model_Name")
                if model:
                    self.model = model
            except Exception:
                pass

        try:
            self.speaker_levels = self.read_speaker_levels()
            if not self.seat_baseline:
                self.seat_baseline = dict(self.speaker_levels)
                self.save_state()
            self.lr_balance = self._calc_lr_balance()
        except Exception:
            pass

    def read_speaker_levels(self) -> dict[str, int]:
        root = self.post(
            "GET",
            "<Main_Zone><Sound_Video><Speaker_Preout><Level>GetParam</Level></Speaker_Preout></Sound_Video></Main_Zone>",
        )
        levels: dict[str, int] = {}
        level_node = root.find(".//Level")
        if level_node is None:
            return levels
        for child in level_node:
            val = child.findtext("Val")
            if val is not None and re.fullmatch(r"-?\d+", val):
                levels[child.tag] = int(val)
        return levels

    def _calc_lr_balance(self) -> int:
        diffs: list[int] = []
        for left, right in LR_PAIRS:
            if left in self.speaker_levels and right in self.speaker_levels:
                cur_l = self.speaker_levels[left]
                cur_r = self.speaker_levels[right]
                base_l = self.seat_baseline.get(left, 0)
                base_r = self.seat_baseline.get(right, 0)
                l_delta = cur_l - base_l
                r_delta = cur_r - base_r
                diffs.append(r_delta - l_delta)
        if not diffs:
            return 0
        avg = sum(diffs) / len(diffs)
        return max(-10, min(10, int(round(avg / 10))))

    def _set_lr_balance(self, step: int) -> None:
        step = max(-10, min(10, step))
        delta = step * 10
        inner: list[str] = []
        for left, right in LR_PAIRS:
            if left in self.speaker_levels and right in self.speaker_levels:
                base_l = self.seat_baseline.get(left, self.speaker_levels[left])
                base_r = self.seat_baseline.get(right, self.speaker_levels[right])
                new_l = max(SPEAKER_LEVEL_MIN, min(SPEAKER_LEVEL_MAX, base_l - delta))
                new_r = max(SPEAKER_LEVEL_MIN, min(SPEAKER_LEVEL_MAX, base_r + delta))
                inner.append(f"<{left}><Val>{new_l}</Val><Exp>1</Exp><Unit>dB</Unit></{left}>")
                inner.append(f"<{right}><Val>{new_r}</Val><Exp>1</Exp><Unit>dB</Unit></{right}>")
        if not inner:
            return
        body = (
            "<Main_Zone><Sound_Video><Speaker_Preout><Level>"
            + "".join(inner)
            + "</Level></Speaker_Preout></Sound_Video></Main_Zone>"
        )
        self.post("PUT", body)
        self.lr_balance = step

    def status_payload(self) -> dict[str, Any]:
        return {
            "host": self.host,
            "name": self.name,
            "model": self.model,
            "power": self.power,
            "mute": self.mute,
            "input": self.input_sel,
            "volume": f"{self.volume_db:.1f}" if self.volume_db is not None else "--",
            "program": self.program,
            "straight": self.straight,
            "enhancer": self.enhancer,
            "pureDirect": self.pure_direct,
            "cinema3d": self.cinema_3d,
            "dialogueLift": self.dialogue_lift,
            "dialogueLvl": self.dialogue_lvl,
            "lrBalance": self.lr_balance,
            "connected": self.connected,
        }

    def dispatch(self, action: str) -> dict[str, Any]:
        if action == "status":
            self.refresh()
            return self.status_payload()
        if action == "power-on":
            self.post("PUT", "<Main_Zone><Power_Control><Power>On</Power></Power_Control></Main_Zone>")
        elif action == "power-off":
            self.post("PUT", "<Main_Zone><Power_Control><Power>Standby</Power></Power_Control></Main_Zone>")
        elif action == "power-toggle":
            target = "Standby" if self.power == "On" else "On"
            self.post("PUT", f"<Main_Zone><Power_Control><Power>{target}</Power></Power_Control></Main_Zone>")
        elif action == "mute-toggle":
            target = "Off" if self.mute == "On" else "On"
            self.post("PUT", f"<Main_Zone><Volume><Mute>{target}</Mute></Volume></Main_Zone>")
        elif action == "vol-up":
            self.post("PUT", "<Main_Zone><Volume><Lvl><Val>Up 5 dB</Val><Exp></Exp><Unit></Unit></Lvl></Volume></Main_Zone>")
        elif action == "vol-down":
            self.post("PUT", "<Main_Zone><Volume><Lvl><Val>Down 5 dB</Val><Exp></Exp><Unit></Unit></Lvl></Volume></Main_Zone>")
        elif action == "input-appletv":
            self.post("PUT", "<Main_Zone><Input><Input_Sel>AV4</Input_Sel></Input></Main_Zone>")
        elif action == "input-shield":
            self.post("PUT", "<Main_Zone><Input><Input_Sel>HDMI1</Input_Sel></Input></Main_Zone>")
        elif action == "input-tv":
            self.post("PUT", "<Main_Zone><Input><Input_Sel>AUDIO1</Input_Sel></Input></Main_Zone>")
        elif action == "input-airplay":
            self.post("PUT", "<Main_Zone><Input><Input_Sel>AirPlay</Input_Sel></Input></Main_Zone>")
        elif action == "input-spotify":
            self.post("PUT", "<Main_Zone><Input><Input_Sel>Spotify</Input_Sel></Input></Main_Zone>")
        elif action == "program-straight":
            target = "Off" if self.straight == "On" else "On"
            self.post("PUT", f"<Main_Zone><Surround><Program_Sel><Current><Straight>{target}</Straight></Current></Program_Sel></Surround></Main_Zone>")
        elif action == "program-surround":
            self.post("PUT", "<Main_Zone><Surround><Program_Sel><Current><Sound_Program>Surround Decoder</Sound_Program></Current></Program_Sel></Surround></Main_Zone>")
        elif action == "program-drama":
            self.post("PUT", "<Main_Zone><Surround><Program_Sel><Current><Sound_Program>Drama</Sound_Program></Current></Program_Sel></Surround></Main_Zone>")
        elif action == "program-scifi":
            self.post("PUT", "<Main_Zone><Surround><Program_Sel><Current><Sound_Program>Sci-Fi</Sound_Program></Current></Program_Sel></Surround></Main_Zone>")
        elif action == "program-music":
            self.post("PUT", "<Main_Zone><Surround><Program_Sel><Current><Sound_Program>7ch Stereo</Sound_Program></Current></Program_Sel></Surround></Main_Zone>")
        elif action == "program-7ch":
            self.post("PUT", "<Main_Zone><Surround><Program_Sel><Current><Sound_Program>7ch Stereo</Sound_Program></Current></Program_Sel></Surround></Main_Zone>")
        elif action == "enhancer-toggle":
            target = "Off" if self.enhancer == "On" else "On"
            self.post("PUT", f"<Main_Zone><Sound_Video><Enhancer>{target}</Enhancer></Sound_Video></Main_Zone>")
        elif action == "puredirect-toggle":
            target = "Off" if self.pure_direct == "On" else "On"
            self.post("PUT", f"<Main_Zone><Sound_Video><Pure_Direct><Mode>{target}</Mode></Pure_Direct></Sound_Video></Main_Zone>")
        elif action == "cinema3d-toggle":
            target = "Off" if self.cinema_3d == "On" else "Auto"
            self.post("PUT", f"<Main_Zone><Surround><_3D_Cinema_DSP>{target}</_3D_Cinema_DSP></Surround></Main_Zone>")
        elif action == "dialogue-lift-up":
            target_lift = min(5, self.dialogue_lift + 1)
            self.post("PUT", f"<Main_Zone><Sound_Video><Dialogue_Adjust><Dialogue_Lift>{target_lift}</Dialogue_Lift></Dialogue_Adjust></Sound_Video></Main_Zone>")
        elif action == "dialogue-lift-down":
            target_lift = max(0, self.dialogue_lift - 1)
            self.post("PUT", f"<Main_Zone><Sound_Video><Dialogue_Adjust><Dialogue_Lift>{target_lift}</Dialogue_Lift></Dialogue_Adjust></Sound_Video></Main_Zone>")
        elif action == "dialogue-lvl-up":
            target_lvl = min(3, self.dialogue_lvl + 1)
            self.post("PUT", f"<Main_Zone><Sound_Video><Dialogue_Adjust><Dialogue_Lvl>{target_lvl}</Dialogue_Lvl></Dialogue_Adjust></Sound_Video></Main_Zone>")
        elif action == "dialogue-lvl-down":
            target_lvl = max(0, self.dialogue_lvl - 1)
            self.post("PUT", f"<Main_Zone><Sound_Video><Dialogue_Adjust><Dialogue_Lvl>{target_lvl}</Dialogue_Lvl></Dialogue_Adjust></Sound_Video></Main_Zone>")
        elif action == "seat-left":
            self._set_lr_balance(self.lr_balance - 1)
        elif action == "seat-right":
            self._set_lr_balance(self.lr_balance + 1)
        elif action == "seat-center":
            self._set_lr_balance(0)
        elif action == "capture-baseline":
            self.seat_baseline = self.read_speaker_levels()
            self.save_state()
        elif action == "restore-baseline":
            if self.seat_baseline:
                inner = [
                    f"<{k}><Val>{v}</Val><Exp>1</Exp><Unit>dB</Unit></{k}>"
                    for k, v in self.seat_baseline.items()
                ]
                body = (
                    "<Main_Zone><Sound_Video><Speaker_Preout><Level>"
                    + "".join(inner)
                    + "</Level></Speaker_Preout></Sound_Video></Main_Zone>"
                )
                self.post("PUT", body)
                self.lr_balance = 0
        else:
            raise ValueError(f"Unknown action: {action[:32]}")
        self.refresh()
        return self.status_payload()

    def handle_request(self, request: dict[str, Any]) -> None:
        operation = str(request.get("op", ""))[:32]
        if operation == "seat-pos":
            x = int(request.get("x", 0))
            y = int(request.get("y", 0))
            x = max(-10, min(10, x))
            y = max(0, min(5, y))
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
            host = str(request.get("host", "")).strip()[:128]
            if not host:
                raise RuntimeError("Enter a host IP")
            resolve_and_validate_lan_ip(host)
            self.host = host
            if request.get("name"):
                self.name = str(request["name"]).strip()[:64]
            self.refresh()
            self.save_state()
            emit("switched", **self.status_payload())
            return
        raise ValueError(f"Unknown operation: {operation}")

    def run(self) -> None:
        try:
            if self.host:
                self.refresh()
            emit("ready", **self.status_payload())
        except Exception as error:
            emit("error", action="connect", message=str(error), connected=False)

        while True:
            line = sys.stdin.readline(MAX_STDIN_LINE)
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
                    action=raw[:32],
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
