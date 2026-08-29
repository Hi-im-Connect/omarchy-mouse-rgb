#!/usr/bin/env python
"""Control layer for the Logitech G203 Lightsync bar widget.

Talks to OpenRGB over its SDK protocol rather than shelling out to the
`openrgb` CLI, because the CLI is unusable for this device:

  * Speed: cli.cpp computes `speed_max - speed_min` into an `unsigned int`.
    This device reports an inverted scale (min=20000, max=1000, higher =
    slower), so that subtraction underflows to ~4.29e9 and the follow-up
    multiply overflows again. Every `--speed` except 0 sends garbage bytes.
    That also takes out Colormixing, which is a speed-only effect.
  * Mode colors: the driver allocates a color slot (`colors.resize(1)`) but
    never sets colors_min/colors_max, so both read 0. The CLI validates
    `count >= min && count <= max` and therefore rejects every color for
    Static and Breathing. The slot itself is real and writable over SDK.
  * Wave direction is implemented in the firmware packet builder (0x01 /
    0x06) but no CLI flag was ever added for it.

Ownership model: this daemon holds the single OpenRGB connection and is the
only writer to the device. `apply` merely writes state.json, so switching
from a software effect to a hardware mode can't race an in-flight animation
frame -- one process, one owner.
"""

import argparse
import colorsys
import json
import math
import os
import subprocess
import sys
import tempfile
import time

STATE_PATH = os.path.expanduser("~/.local/share/mouse-rgb/state.json")
STATUS_PATH = os.path.expanduser("~/.local/share/mouse-rgb/status.json")
POLL_INTERVAL = 0.05

# The mouse exposes RGB (OpenRGB) and DPI/polling rate (ratbagd) over the
# same HID++ channel, and it does not cope with both at once: animating in
# Direct mode at 60fps starved ratbagd into "USB error: Connection timed out
# (110)" and left it unable to commit a profile. So the daemon is the single
# serialization point for the device -- it pauses animation around every
# ratbagctl call, and clients read cached status instead of querying the
# hardware themselves. 30fps is plenty smooth for these effects and halves
# the bus pressure.
EFFECT_FPS = 30

# Direct mode is a live stream, not a stored setting: the mouse's own
# firmware watches for frames and falls back to its onboard default effect
# (the "colors it comes with") if the host goes quiet for a few seconds --
# the same watchdog that makes screensavers necessary on some of these
# controllers. So Solid needs a periodic no-op resend even when nothing has
# changed, well inside whatever the real timeout turns out to be.
SOLID_HEARTBEAT_INTERVAL = 2.0

# Hardware effects, keyed by our id -> OpenRGB mode name.
HARDWARE_MODES = {
    "off": "Off",
    "solid": "Direct",
    "static": "Static",
    "breathing": "Breathing",
    "cycle": "Cycle",
    "wave": "Wave",
    "colormix": "Colormixing",
}

# Effects we animate ourselves in Direct mode, for things the firmware
# cannot do (its Breathing carries a single color, so 2-color breathing has
# to be software).
SOFTWARE_MODES = ("dual_breathing", "rainbow")

DEFAULT_STATE = {
    "mode": "solid",
    "colors": ["AF52DE", "00E5FF", "FFD60A"],
    "perLed": False,
    "speed": 50,
    "brightness": 100,
    "direction": 0,
    # None means "leave whatever the device already has alone".
    "dpi": None,
    "rate": None,
}


# --------------------------------------------------------------------------
# state file
# --------------------------------------------------------------------------

def read_state():
    state = dict(DEFAULT_STATE)
    try:
        with open(STATE_PATH) as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict):
            state.update(loaded)
    except (OSError, ValueError):
        pass
    colors = state.get("colors") or []
    colors = [c for c in colors if isinstance(c, str) and len(c) == 6]
    while len(colors) < 3:
        colors.append(DEFAULT_STATE["colors"][len(colors)])
    state["colors"] = colors[:3]
    return state


def write_state(patch):
    state = read_state()
    state.update(patch)
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    # Atomic replace so the daemon never reads a half-written file.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(STATE_PATH))
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(state, fh)
        os.replace(tmp, STATE_PATH)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return state


# --------------------------------------------------------------------------
# color helpers
# --------------------------------------------------------------------------

def hex_to_rgb(value):
    value = (value or "").lstrip("#")
    if len(value) != 6:
        return (0, 0, 0)
    try:
        return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))
    except ValueError:
        return (0, 0, 0)


def scale(rgb, factor):
    factor = max(0.0, min(1.0, factor))
    return tuple(int(round(c * factor)) for c in rgb)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def hue_rgb(hue):
    r, g, b = colorsys.hsv_to_rgb((hue % 360.0) / 360.0, 1.0, 1.0)
    return (int(r * 255), int(g * 255), int(b * 255))


# --------------------------------------------------------------------------
# scaling into device units
# --------------------------------------------------------------------------

def hw_speed(mode, percent):
    """Map 0-100% onto the mode's own raw range, honouring inverted scales.

    This device reports speed_min=20000, speed_max=1000 -- the raw value is a
    period, so a *lower* number is faster and min > max. Interpolating from
    min toward max handles both orientations without special-casing.
    """
    lo, hi = mode.speed_min, mode.speed_max
    if lo is None or hi is None:
        return None
    percent = max(0, min(100, percent))
    return int(round(lo + (hi - lo) * (percent / 100.0)))


def hw_brightness(mode, percent):
    lo, hi = mode.brightness_min, mode.brightness_max
    if lo is None or hi is None:
        return None
    percent = max(0, min(100, percent))
    return int(round(lo + (hi - lo) * (percent / 100.0)))


def effect_period(percent):
    """Seconds per animation cycle for software effects."""
    percent = max(0, min(100, percent))
    return 8.0 - (7.6 * percent / 100.0)


# --------------------------------------------------------------------------
# libratbag (DPI / polling rate) -- a separate stack from OpenRGB
# --------------------------------------------------------------------------

RATBAGCTL = ["/usr/bin/python3", "/usr/bin/ratbagctl"]


def ratbag_device():
    try:
        out = subprocess.run(RATBAGCTL + ["list"], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        if "Logitech" in line or "Lightsync" in line:
            name = line.split(":", 1)[0].strip()
            if name:
                return name
    return ""


def ratbag(*args):
    device = ratbag_device()
    if not device:
        return ""
    try:
        return subprocess.run(RATBAGCTL + [device] + [str(a) for a in args],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def first_int(text, fallback=0):
    digits = ""
    for ch in text or "":
        if ch.isdigit():
            digits += ch
        elif digits:
            break
    return int(digits) if digits else fallback


# --------------------------------------------------------------------------
# OpenRGB
# --------------------------------------------------------------------------

def connect(name="mouse-rgb"):
    from openrgb import OpenRGBClient
    return OpenRGBClient("127.0.0.1", 6742, name)


def find_device(client):
    for dev in client.devices:
        if "G203" in dev.name or "Lightsync" in dev.name:
            return dev
    return client.devices[0] if client.devices else None


def apply_hardware(device, state):
    from openrgb.utils import RGBColor

    mode_name = HARDWARE_MODES.get(state["mode"], "Direct")
    mode = next((m for m in device.modes if m.name == mode_name), None)
    if mode is None:
        return

    if mode_name == "Direct":
        device.set_mode(mode)
        rgb = [hex_to_rgb(c) for c in state["colors"]]
        factor = state.get("brightness", 100) / 100.0
        if state.get("perLed"):
            colors = [RGBColor(*scale(rgb[i], factor)) for i in range(3)]
        else:
            colors = [RGBColor(*scale(rgb[0], factor))] * 3
        device.set_colors(colors)
        return

    speed = hw_speed(mode, state.get("speed", 50))
    if speed is not None:
        mode.speed = speed
    brightness = hw_brightness(mode, state.get("brightness", 100))
    if brightness is not None:
        mode.brightness = brightness
    if mode.direction is not None:
        mode.direction = 1 if state.get("direction") else 0
    if mode.colors is not None and len(mode.colors) > 0:
        mode.colors = [RGBColor(*hex_to_rgb(state["colors"][0]))]
        # The driver leaves these at 0, which is what makes the CLI reject
        # every color. Declaring the slot we actually filled keeps the
        # server-side count consistent with the payload.
        mode.colors_min = 1
        mode.colors_max = 1
    device.set_mode(mode)


def software_frame(device, state, elapsed):
    from openrgb.utils import RGBColor

    period = effect_period(state.get("speed", 50))
    factor = state.get("brightness", 100) / 100.0
    phase = (elapsed % period) / period

    if state["mode"] == "dual_breathing":
        a = hex_to_rgb(state["colors"][0])
        b = hex_to_rgb(state["colors"][1])
        # Cosine ease so the hold at each end feels like a breath rather
        # than a linear ping-pong.
        t = (1 - math.cos(2 * math.pi * phase)) / 2
        colors = [RGBColor(*scale(lerp(a, b, t), factor))] * 3
    else:  # rainbow
        base = phase * 360.0
        # Small per-LED offset so the sweep reads as movement across the
        # three LEDs instead of all of them flashing in unison.
        colors = [RGBColor(*scale(hue_rgb(base + i * 40), factor)) for i in range(3)]

    device.set_colors(colors, fast=True)


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_status(_args):
    """Serve the daemon's cached snapshot.

    Deliberately does no device I/O: querying ratbagd while the daemon is
    animating is exactly what triggers the HID++ contention described above.
    """
    state = read_state()
    info = {
        "connected": False,
        "device": "",
        "dpi": 0,
        "rate": 0,
        "dpiAvailable": False,
    }
    try:
        with open(STATUS_PATH) as fh:
            cached = json.load(fh)
        if isinstance(cached, dict):
            info.update(cached)
    except (OSError, ValueError):
        pass
    # Carry the persisted settings too, so a freshly-restarted panel opens
    # showing what the mouse is actually doing rather than its own defaults.
    for key in ("mode", "colors", "perLed", "speed", "brightness", "direction"):
        info[key] = state[key]
    print(json.dumps(info))


def cmd_apply(args):
    patch = json.loads(args.state) if args.state else {}
    write_state(patch)


def cmd_dpi(args):
    write_state({"dpi": int(args.value)})


def cmd_rate(args):
    write_state({"rate": int(args.value)})


def write_status(info):
    os.makedirs(os.path.dirname(STATUS_PATH), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(STATUS_PATH))
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(info, fh)
        os.replace(tmp, STATUS_PATH)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def refresh_peripheral_status(device):
    """Read DPI/rate straight from the hardware. Callers must not be animating."""
    info = {
        "connected": device is not None,
        "device": device.name if device is not None else "",
        "dpi": 0,
        "rate": 0,
        "dpiAvailable": False,
    }
    if ratbag_device():
        info["dpiAvailable"] = True
        info["dpi"] = first_int(ratbag("dpi", "get"))
        info["rate"] = first_int(ratbag("rate", "get"))
    write_status(info)
    return info


def cmd_effectd(_args):
    device = None
    last_mtime = None
    state = read_state()
    effect_start = time.monotonic()
    active_software = None
    applied_dpi = None
    applied_rate = None
    status = {}
    last_solid_heartbeat = 0.0

    while True:
        if device is None:
            try:
                device = find_device(connect("mouse-rgb-daemon"))
            except Exception:
                time.sleep(2.0)
                continue
            last_mtime = None  # force a re-apply once reconnected
            status = refresh_peripheral_status(device)
            # Seed from the hardware so a stale state file can't stomp a DPI
            # the user set elsewhere on the very first poll.
            applied_dpi = status.get("dpi") or None
            applied_rate = status.get("rate") or None

        try:
            mtime = os.path.getmtime(STATE_PATH)
        except OSError:
            mtime = 0

        state_changed = mtime != last_mtime
        # Solid is Direct mode, a live stream the firmware watchdogs -- see
        # SOLID_HEARTBEAT_INTERVAL. Resend on a timer even without a change.
        due_for_heartbeat = (
            not state_changed
            and state["mode"] == "solid"
            and time.monotonic() - last_solid_heartbeat >= SOLID_HEARTBEAT_INTERVAL
        )

        if state_changed or due_for_heartbeat:
            if state_changed:
                last_mtime = mtime
                state = read_state()

            want_dpi = state.get("dpi")
            want_rate = state.get("rate")
            peripheral_changed = (state_changed and
                                  ((want_dpi and want_dpi != applied_dpi) or
                                   (want_rate and want_rate != applied_rate)))

            try:
                # Order matters: DPI/rate first, with no animation frames in
                # flight, so ratbagd gets the HID++ channel to itself.
                if peripheral_changed:
                    if want_dpi and want_dpi != applied_dpi:
                        ratbag("dpi", "set", want_dpi)
                        applied_dpi = want_dpi
                    if want_rate and want_rate != applied_rate:
                        ratbag("rate", "set", want_rate)
                        applied_rate = want_rate
                    refresh_peripheral_status(device)

                if state["mode"] in SOFTWARE_MODES:
                    if active_software != state["mode"] or peripheral_changed:
                        direct = next((m for m in device.modes if m.name == "Direct"), None)
                        if direct is not None:
                            device.set_mode(direct)
                        effect_start = time.monotonic()
                        active_software = state["mode"]
                else:
                    active_software = None
                    apply_hardware(device, state)
                    if state["mode"] == "solid":
                        last_solid_heartbeat = time.monotonic()
            except Exception:
                device = None
                continue

        if state["mode"] in SOFTWARE_MODES:
            try:
                software_frame(device, state, time.monotonic() - effect_start)
            except Exception:
                device = None
                continue
            time.sleep(1 / EFFECT_FPS)
        else:
            time.sleep(POLL_INTERVAL)


def main():
    parser = argparse.ArgumentParser(description="Logitech G203 Lightsync control")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status").set_defaults(func=cmd_status)

    p_apply = sub.add_parser("apply")
    p_apply.add_argument("state", help="JSON patch merged into the stored state")
    p_apply.set_defaults(func=cmd_apply)

    p_dpi = sub.add_parser("dpi")
    p_dpi.add_argument("value")
    p_dpi.set_defaults(func=cmd_dpi)

    p_rate = sub.add_parser("rate")
    p_rate.add_argument("value")
    p_rate.set_defaults(func=cmd_rate)

    sub.add_parser("effectd").set_defaults(func=cmd_effectd)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
