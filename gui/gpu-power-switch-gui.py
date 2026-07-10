"""gpu-power-switch-gui — Adwaita frontend for the gpu-power-switch service.

Displays:
  * Real-time power draw (battery discharge rate + CPU RAPL + GPU NVML)
  * Estimated battery runtime
  * NVIDIA dGPU status + manual toggle
  * Global "auto-switch on AC change" enable/disable

Communication with the privileged backend:
  * Reads status + measurements via plain sysfs (read-only — no root needed
    for these paths on most distros)
  * Writes to sysfs (GPU power, profile) go through pkexec → polkit policy
    so the user does not need to type a password on each press.

Single-instance: a UNIX socket at $XDG_RUNTIME_DIR/gpu-power-switch.sock
is held while a window is open. A second invocation sends a "show" line and
exits — so a .desktop / launcher / autostart entry always brings the existing
window forward instead of spawning a duplicate.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, GObject, Gtk  # noqa: E402

APP_ID = "org.linuxbatterysaver.Gui"
APP_VERSION = "0.2.0"
SCRIPT_PATH = "/usr/lib/gpu-power-switch/gpu-power-switch.sh"
TOGGLE_HELPER = "/usr/lib/gpu-power-switch/gpu-power-switch-toggle"
MANUAL_HELPER = "/usr/lib/gpu-power-switch/gpu-power-switch-manual"
SOCKET_PATH = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}") + "/gpu-power-switch.sock"

POLL_INTERVAL_MS = 1500  # how often to refresh power/charge data

# ────────────────────────────────────────────────────────────────────
# Data classes
# ────────────────────────────────────────────────────────────────────


@dataclass
class PowerReading:
    battery_w: Optional[float]   # current discharge (+) / charge (−) power in W
    cpu_w: Optional[float]       # package RAPL power in W
    gpu_w: Optional[float]       # NVIDIA dGPU power in W
    charge_pct: Optional[float]
    charge_wh: Optional[float]   # remaining energy (Wh)
    charge_full_wh: Optional[float]
    ac_online: bool
    gpu_control: str             # "on" | "auto" | "unknown"
    gpu_present: bool
    profile: str                 # "performance" | "balanced" | "power-saver" | "unknown"
    enabled: bool
    manual: bool
    bat_time: str                # upower's "time to empty" / "time to full"
    helper_ran: bool             # True iff the helper was invoked this tick
    timestamp: float


# ────────────────────────────────────────────────────────────────────
# Power data acquisition (no root required for *reading* these paths)
# ────────────────────────────────────────────────────────────────────

_BAT_RE = re.compile(r"BAT\d+$")


def _read_int(path: Path) -> Optional[int]:
    try:
        return int(path.read_text().strip())
    except (FileNotFoundError, ValueError, OSError):
        return None


def read_status_via_helper(use_pkexec: bool = True) -> dict:
    """Run the helper script (status) and parse its key=value output.

    The helper needs root to read RAPL energy_uj and the power_supply
    files; we use pkexec + polkit for that. The polkit policy is
    allow_active=yes so the user is NOT prompted for a password on a
    single-user machine — but on first run, the polkit GUI agent may
    not yet be registered, in which case pkexec returns 1 with an
    empty body. We fall back to running the helper without pkexec
    (which succeeds for the fields that do not need root) and then
    layer the root-only fields on top once the polkit agent responds.
    """
    out: dict = {}
    # Try pkexec first (root) so we get RAPL
    if use_pkexec and shutil.which("pkexec"):
        try:
            r = subprocess.run(
                ["pkexec", SCRIPT_PATH, "status"],
                capture_output=True, text=True, timeout=5, check=False,
            )
            if r.returncode == 0 and r.stdout.strip():
                for line in r.stdout.splitlines():
                    if "=" in line:
                        k, _, v = line.partition("=")
                        out[k.strip()] = v.strip()
                return out
        except (subprocess.SubprocessError, OSError):
            pass
    # Fallback: run without pkexec. We get the fields that are
    # world-readable (gpu_control, ac_online, enabled, ...). RAPL and
    # the manual lock file are NOT included; the poller will retry
    # pkexec on the next tick and eventually succeed once the polkit
    # agent is registered.
    try:
        r = subprocess.run(
            [SCRIPT_PATH, "status"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        if r.returncode == 0 and r.stdout.strip():
            for line in r.stdout.splitlines():
                if "=" in line:
                    k, _, v = line.partition("=")
                    out[k.strip()] = v.strip()
    except (subprocess.SubprocessError, OSError):
        pass
    return out


def read_battery() -> tuple[Optional[float], Optional[float], Optional[float], Optional[float]]:
    """Return (discharge_W, charge_pct, now_Wh, full_Wh).

    The kernel may expose the battery either as energy_* (Wh, in µWh
    units) or charge_* (µAh, no Wh without voltage). For the energy_*
    case we can directly compute Wh; for the charge_* case we have
    no voltage-at-rest data so the Wh values are returned as None —
    callers that need Wh should fall back to upower (which has the
    proper voltage) instead of guessing.
    """
    base = Path("/sys/class/power_supply")
    if not base.exists():
        return None, None, None, None
    now_wh = full_wh = pct = None
    power_w = None
    for bat in base.iterdir():
        if not _BAT_RE.match(bat.name):
            continue
        if now_wh is None and (bat / "energy_now").exists() and (bat / "energy_full").exists():
            p_now = _read_int(bat / "energy_now")
            p_full = _read_int(bat / "energy_full")
            if p_now is not None and p_full is not None:
                now_wh = p_now / 1_000_000.0
                full_wh = p_full / 1_000_000.0
        p_power = _read_int(bat / "power_now")
        if p_power is not None:
            power_w = p_power / 1_000_000.0
        else:
            cur = _read_int(bat / "current_now")
            volt = _read_int(bat / "voltage_now")
            if cur is not None and volt is not None:
                power_w = (cur * volt) / 1_000_000_000_000.0
        p_pct = _read_int(bat / "capacity")
        if p_pct is not None and pct is None:
            pct = float(p_pct)
    return power_w, pct, now_wh, full_wh


def read_cpu_power() -> Optional[float]:
    """Sum of all /sys/class/powercap/intel-rapl:*:0/energy_uj deltas."""
    base = Path("/sys/class/powercap")
    if not base.exists():
        return None
    total = 0.0
    ok = False
    # Only sum true *package* domains (e.g. intel-rapl:0, intel-rapl:mmio:0),
    # NOT the inner core/uncache sub-zones which would double-count.
    for p in base.glob("intel-rapl*"):
        name_file = p / "name"
        if not name_file.exists():
            continue
        try:
            name = name_file.read_text().strip()
        except OSError:
            continue
        if not name.startswith("package-"):
            continue
        energy = p / "energy_uj"
        if not energy.exists():
            continue
        try:
            total += int(energy.read_text().strip())
            ok = True
        except (ValueError, OSError):
            continue
    return total / 1_000_000.0 if ok else None  # µJ → J, but for instantaneous W we need a delta


def read_rapl_w() -> Optional[float]:
    """Return package power in W by sampling RAPL energy twice ~250 ms apart."""
    def sample() -> Optional[int]:
        total = 0
        ok = False
        for p in Path("/sys/class/powercap").glob("intel-rapl*"):
            name_file = p / "name"
            if not name_file.exists():
                continue
            try:
                name = name_file.read_text().strip()
            except OSError:
                continue
            if not name.startswith("package-"):
                continue
            try:
                total += int((p / "energy_uj").read_text().strip())
                ok = True
            except (ValueError, OSError):
                continue
        return total if ok else None
    a = sample()
    if a is None:
        return None
    time.sleep(0.25)
    b = sample()
    if b is None or b < a:
        return None
    return (b - a) / 1_000_000.0 / 0.25  # µJ → J → W


def read_nvidia_power() -> Optional[float]:
    """Instantaneous GPU power in W via nvidia-smi (no extra Python deps)."""
    if not shutil.which("nvidia-smi"):
        return None
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=power.draw", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=3, check=False,
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return None
    if not out:
        return None
    try:
        return float(out.splitlines()[0])
    except ValueError:
        return None


def read_ac_online() -> bool:
    base = Path("/sys/class/power_supply")
    if not base.exists():
        return False
    for f in base.glob("AC*/online"):
        try:
            if int(f.read_text().strip()) == 1:
                return True
        except (ValueError, OSError):
            continue
    for f in base.glob("AC*/status"):
        try:
            if f.read_text().strip() in ("Charging", "Full"):
                return True
        except (OSError,):
            continue
    return False


def read_enabled() -> bool:
    p = Path("/etc/gpu-power-switch/enabled")
    if not p.exists():
        return True
    try:
        return p.read_text().strip().lower() not in ("0", "false", "no", "off", "disabled")
    except OSError:
        return True


# ────────────────────────────────────────────────────────────────────
# Privileged actions via pkexec + polkit
# ────────────────────────────────────────────────────────────────────

def _pkexec_root(argv: list[str]) -> tuple[int, str]:
    """Run argv[0] as root with polkit. Used for state-changing actions
    where the user *will* see a polkit dialog the first time.
    """
    if shutil.which("pkexec") is None:
        return 127, "pkexec not installed"
    try:
        r = subprocess.run(["pkexec", *argv], capture_output=True, text=True, timeout=15)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.SubprocessError as e:
        return 1, str(e)


def _pkexec_status(argv: list[str]) -> tuple[int, str]:
    """Same as _pkexec_root but with a longer timeout (helper sleeps
    ~250 ms to compute RAPL delta). Used for status polls.
    """
    if shutil.which("pkexec") is None:
        return 127, "pkexec not installed"
    try:
        r = subprocess.run(["pkexec", *argv], capture_output=True, text=True, timeout=5)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.SubprocessError as e:
        return 1, str(e)


def gpu_set_power(mode: str) -> tuple[bool, str]:
    """Wake (mode='on') or suspend (mode='auto') the dGPU. This is the
    action the user explicitly invoked — we also set/clear the manual
    lock so AC events stop fighting the choice until the user re-enables
    auto-mode in the GUI.
    """
    helper_action = "on" if mode == "on" else "auto"
    rc, msg = _pkexec_root([MANUAL_HELPER, helper_action])
    return rc == 0, msg


def gpu_set_profile(profile: str) -> tuple[bool, str]:
    rc, msg = _pkexec_root([SCRIPT_PATH, "set-profile", profile])
    return rc == 0, msg


def gpu_set_enabled(enabled: bool) -> tuple[bool, str]:
    rc, msg = _pkexec_root([TOGGLE_HELPER, "on" if enabled else "off"])
    return rc == 0, msg


def gpu_set_manual_lock(locked: bool) -> tuple[bool, str]:
    """Set/clear the manual-mode lock without touching GPU state."""
    rc, msg = _pkexec_root([MANUAL_HELPER, "lock" if locked else "unlock"])
    return rc == 0, msg


# ────────────────────────────────────────────────────────────────────
# Polling thread
# ────────────────────────────────────────────────────────────────────


class Poller(GObject.Object):
    """Polls system data on a worker thread; emits 'reading' on the main loop."""

    __gsignals__ = {"reading": (GObject.SignalFlags.RUN_FIRST, None, (object,))}

    def __init__(self) -> None:
        super().__init__()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        # Optional debug log; set GPU_PSWITCH_DEBUG=1 to enable.
        self._debug = bool(os.environ.get("GPU_PSWITCH_DEBUG"))

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="gpa-poller", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        prev_energy = None
        prev_time = None
        # First poll: use the helper (which has root) immediately so the
        # user does not see an empty CPU row for 6 seconds. Subsequent
        # polls use helper only every 4th tick to avoid the 0.25 s sleep
        # on every refresh.
        cycle = 0
        while not self._stop.is_set():
            cycle += 1
            use_helper = (cycle == 1) or (cycle % 4 == 0)
            helper = read_status_via_helper() if use_helper else {}
            if self._debug:
                with open("/tmp/gpa-debug.log", "a") as f:
                    f.write(f"[tick {cycle} helper={use_helper}] {helper}\n")

            bat_w = None
            pct = None
            now_wh = None
            full_wh = None
            cpu_w = None
            gpu_w = None
            ac = read_ac_online()
            enabled = (helper.get("enabled", "").lower() == "true") if use_helper else read_enabled()
            manual = (helper.get("manual", "").lower() == "true") if use_helper else Path(
                "/var/lib/gpu-power-switch/manual.lock"
            ).exists()
            # Battery fields (when helper ran)
            bat_time = ""
            if use_helper:
                if helper.get("bat_w"):
                    try: bat_w = float(helper["bat_w"])
                    except ValueError: pass
                if helper.get("bat_pct"):
                    try: pct = float(helper["bat_pct"])
                    except ValueError: pass
                if helper.get("bat_energy_wh"):
                    try: now_wh = float(helper["bat_energy_wh"])
                    except ValueError: pass
                if helper.get("bat_energy_full_wh"):
                    try: full_wh = float(helper["bat_energy_full_wh"])
                    except ValueError: pass
                bat_time = helper.get("bat_time", "") or ""
            # sysfs fallback for capacity (helper may not run, or upower missing)
            if pct is None:
                _bw, _pct, _now, _full = read_battery()
                if bat_w is None: bat_w = _bw
                if pct is None: pct = _pct
                if now_wh is None: now_wh = _now
                if full_wh is None: full_wh = _full

            cpu_w = None
            if use_helper:
                # Helper ran this tick — RAPL is its exclusive source.
                # Reading energy_uj ourselves never works (root-only
                # sysfs), so we either take the helper value or accept
                # None for this tick.
                rapl_str = helper.get("rapl_w", "") or ""
                if rapl_str:
                    vals = [v for v in rapl_str.split(",") if v]
                    try:
                        cpu_w = sum(float(v) for v in vals)
                    except ValueError:
                        cpu_w = None

            gpu_w = read_nvidia_power()
            gpu_control = "unknown"
            gpu_present = False
            for d in Path("/sys/bus/pci/devices").iterdir():
                try:
                    if (d / "vendor").read_text().strip() != "0x10de":
                        continue
                    cls = (d / "class").read_text().strip()
                    if not (cls.startswith("0x03000") or cls.startswith("0x03020")):
                        continue
                    gpu_present = True
                    ctrl = d / "power/control"
                    if ctrl.exists():
                        gpu_control = ctrl.read_text().strip()
                except OSError:
                    continue
            profile = "unknown"
            try:
                # powerprofilesctl 0.30 has a known BrokenPipeError
                # crash on some systems (GNOME Apport then reports the
                # binary as a crash). Wrap with a short timeout and
                # swallow exit codes so the GUI is unaffected.
                r = subprocess.run(
                    ["powerprofilesctl", "get"],
                    capture_output=True, text=True, timeout=2, check=False,
                )
                if r.returncode == 0 and r.stdout.strip():
                    profile = r.stdout.strip()
            except (subprocess.SubprocessError, OSError, BrokenPipeError):
                # Fall back to the last known good profile; if we have
                # not observed one yet, infer from current settings.
                profile = profile if profile and profile != "unknown" else self._infer_profile()
            else:
                if profile == "unknown" and r.returncode != 0:
                    profile = self._infer_profile()

            reading = PowerReading(
                battery_w=bat_w,
                cpu_w=cpu_w,
                gpu_w=gpu_w,
                charge_pct=pct,
                charge_wh=now_wh,
                charge_full_wh=full_wh,
                ac_online=ac,
                gpu_control=gpu_control,
                gpu_present=gpu_present,
                profile=profile,
                enabled=enabled,
                manual=manual,
                bat_time=bat_time,
                helper_ran=use_helper,
                timestamp=time.time(),
            )
            GLib.idle_add(lambda r=reading: self.emit("reading", r) or False)
            self._stop.wait(POLL_INTERVAL_MS / 1000.0)


# ────────────────────────────────────────────────────────────────────
# Main window
# ────────────────────────────────────────────────────────────────────


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application) -> None:
        super().__init__(application=app, default_width=520, default_height=640)
        self.set_title("Linux Battery Saver")
        self.connect("close-request", self._on_close_request)

        # Header
        header = Adw.HeaderBar()
        about_btn = Gtk.Button(icon_name="help-about-symbolic", tooltip_text="About")
        about_btn.connect("clicked", lambda *_: self._show_about())
        header.pack_end(about_btn)

        # Global enable row (placed in header as a switch)
        self.global_switch = Gtk.Switch(valign=Gtk.Align.CENTER)
        self.global_switch.connect("state-set", self._on_global_toggle)
        header.pack_start(self.global_switch)

        # Toast overlay
        toast_overlay = Adw.ToastOverlay()
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        main_box.append(header)
        main_box.append(self._build_content())
        toast_overlay.set_child(main_box)
        self.set_content(toast_overlay)
        self._toast_overlay = toast_overlay

        # Polling
        self._poller = Poller()
        self._poller.connect("reading", self._on_reading)
        self._poller.start()

    # ─── build UI ───

    def _build_content(self) -> Gtk.Widget:
        clamp = Adw.Clamp(maximum_size=560)
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                    margin_top=12, margin_bottom=24, margin_start=12, margin_end=12)

        # ── Power status group ──
        self.status_group = Adw.PreferencesGroup(title="Power", description="Real-time system power consumption")
        self.power_row = Adw.ActionRow(title="—", subtitle="—")
        self.power_row.add_prefix(Gtk.Image.new_from_icon_name("battery-symbolic"))
        self.cpu_row = Adw.ActionRow(title="CPU", subtitle="—")
        self.cpu_row.add_prefix(Gtk.Image.new_from_icon_name("speedometer-symbolic"))
        self.gpu_power_row = Adw.ActionRow(title="GPU", subtitle="—")
        self.gpu_power_row.add_prefix(Gtk.Image.new_from_icon_name("video-display-symbolic"))
        self.status_group.add(self.power_row)
        self.status_group.add(self.cpu_row)
        self.status_group.add(self.gpu_power_row)
        v.append(self.status_group)

        # ── Battery group ──
        self.battery_group = Adw.PreferencesGroup(title="Battery")
        self.charge_row = Adw.ActionRow(title="Charge", subtitle="—")
        self.charge_row.add_prefix(Gtk.Image.new_from_icon_name("battery-full-symbolic"))
        self.runtime_row = Adw.ActionRow(title="Estimated runtime", subtitle="—")
        self.runtime_row.add_prefix(Gtk.Image.new_from_icon_name("alarm-symbolic"))
        self.profile_row = Adw.ActionRow(title="Power profile", subtitle="—")
        self.profile_row.add_prefix(Gtk.Image.new_from_icon_name("power-profile-balanced-symbolic"))
        self.battery_group.add(self.charge_row)
        self.battery_group.add(self.runtime_row)
        self.battery_group.add(self.profile_row)
        v.append(self.battery_group)

        # ── GPU control group ──
        self.gpu_group = Adw.PreferencesGroup(
            title="NVIDIA dGPU",
            description="Discrete GPU power state and manual control",
        )
        self.gpu_state_row = Adw.ActionRow(title="PCI power control", subtitle="detecting…")
        self.gpu_state_row.add_prefix(Gtk.Image.new_from_icon_name("video-display-symbolic"))
        self.gpu_pci_row = Adw.ActionRow(title="Address", subtitle="—")
        self.gpu_pci_row.add_prefix(Gtk.Image.new_from_icon_name("pci-symbolic"))
        self.gpu_group.add(self.gpu_state_row)
        self.gpu_group.add(self.gpu_pci_row)

        # Manual control: one switch + two action buttons.
        #
        # The switch decides WHO controls the GPU:
        #   OFF  → "Manual" — the buttons below are active, the lock is
        #          set so AC events do not override the user's choice.
        #   ON   → "Auto"   — the lock is cleared and the udev rule
        #          follows AC. The buttons are hidden.
        #
        # The buttons set the actual power state when in Manual mode.
        self.gpu_mode_row = Adw.ActionRow(
            title="Auto-switch on AC change",
            subtitle="…",
        )
        self.gpu_mode_switch = Gtk.Switch(valign=Gtk.Align.CENTER)
        self.gpu_mode_switch.connect("state-set", self._on_mode_toggle)
        self.gpu_mode_row.add_suffix(self.gpu_mode_switch)
        self.gpu_mode_row.set_activatable_widget(self.gpu_mode_switch)
        self.gpu_group.add(self.gpu_mode_row)

        # Two action buttons; visible only in Manual mode.
        self.gpu_action_row = Adw.ActionRow(
            title="Manual override",
            subtitle="Click a button to force the dGPU into this state",
        )
        self.btn_gpu_on = Gtk.Button(label="Wake (on)", valign=Gtk.Align.CENTER,
                                     css_classes=("suggested-action",))
        self.btn_gpu_on.connect("clicked", lambda *_: self._do_action("gpu_on"))
        self.btn_gpu_off = Gtk.Button(label="Suspend (auto)", valign=Gtk.Align.CENTER)
        self.btn_gpu_off.connect("clicked", lambda *_: self._do_action("gpu_off"))
        box = Gtk.Box(spacing=6)
        box.append(self.btn_gpu_on)
        box.append(self.btn_gpu_off)
        self.gpu_action_row.add_suffix(box)
        self.gpu_group.add(self.gpu_action_row)

        v.append(self.gpu_group)

        # Footer
        footer = Gtk.Label(
            label="Polling every 1.5 s · auto-switch runs as root via udev",
            css_classes=("dim-label", "caption"),
            margin_top=12,
        )
        v.append(footer)

        clamp.set_child(v)
        return clamp

    # ─── actions / updates ───

    def _on_reading(self, _src, r: PowerReading) -> None:
        # Power row — keep last subtitle if we have no battery data
        # this tick (e.g. on battery-based systems with no power_now).
        # upower always reports energy-rate as a positive number. The
        # direction (charging vs discharging) is given by ac_online +
        # the kernel's "status" sysfs.
        if r.battery_w is not None and r.battery_w > 0:
            if r.ac_online:
                parts = [f"Charging {r.battery_w:.1f} W"]
            else:
                parts = [f"Discharge {r.battery_w:.1f} W"]
        else:
            parts = []
        if r.ac_online:
            parts.append("on AC")
        else:
            parts.append("on battery")
        if parts:
            self.power_row.set_title("System")
            self.power_row.set_subtitle(" · ".join(parts))
        else:
            cur = self.power_row.get_subtitle() or ""
            if cur == "—" or not cur:
                self.power_row.set_subtitle(
                    f"{'Charging' if r.ac_online else '—'} (no BAT power_now)"
                )

        self.cpu_row.set_subtitle(
            f"{r.cpu_w:.1f} W" if r.cpu_w is not None
            else (self.cpu_row.get_subtitle() or "n/a (no RAPL)")
        )
        if r.gpu_w is not None:
            self.gpu_power_row.set_subtitle(f"{r.gpu_w:.1f} W")
        else:
            # Keep last value if we have one; otherwise show n/a.
            cur = self.gpu_power_row.get_subtitle() or ""
            if "—" in cur or "n/a" in cur:
                self.gpu_power_row.set_subtitle(
                    "n/a (no nvidia-smi)" if not r.gpu_present else "—"
                )

        # Battery
        if r.charge_pct is not None:
            self.charge_row.set_subtitle(f"{r.charge_pct:.0f} %")
        elif r.charge_wh is not None and r.charge_full_wh:
            self.charge_row.set_subtitle(f"{r.charge_wh:.1f} / {r.charge_full_wh:.1f} Wh")
        else:
            self.charge_row.set_subtitle("—")

        # Runtime row: helper is the only reliable source of battery
        # Wh on systems that expose charge_* (µAh) instead of
        # energy_* (µWh). sysfs-only math is off by 1000x and gives
        # nonsense like '4 min' for a healthy 60 min battery. So:
        # only update the runtime row on a tick where the helper ran
        # and provided a value; otherwise keep the last reading.
        if r.helper_ran:
            cur_runtime = self.runtime_row.get_subtitle() or ""
            new_runtime = None
            if r.bat_time and r.bat_time.strip():
                new_runtime = r.bat_time.strip()
            elif r.charge_wh and r.battery_w and r.battery_w > 0 and not r.ac_online:
                minutes = r.charge_wh / r.battery_w * 60.0
                new_runtime = self._fmt_duration(minutes)
            elif r.charge_pct and r.charge_full_wh and r.battery_w and r.battery_w > 0 and not r.ac_online:
                now_wh = r.charge_pct / 100.0 * r.charge_full_wh
                minutes = now_wh / r.battery_w * 60.0
                new_runtime = self._fmt_duration(minutes)
            elif r.ac_online:
                if not cur_runtime or cur_runtime == "—":
                    new_runtime = "∞ (charging / on AC)"
            if new_runtime is not None:
                self.runtime_row.set_subtitle(new_runtime)

        self.profile_row.set_subtitle(r.profile)

        # GPU
        if r.gpu_present:
            self.gpu_state_row.set_subtitle(r.gpu_control)
            self.gpu_pci_row.set_subtitle(
                self._find_nvidia_pci_addr() or "—"
            )
        else:
            self.gpu_state_row.set_subtitle("no NVIDIA 3D controller found")
            self.gpu_pci_row.set_subtitle("—")

        # Auto-switch state
        #   switch ON  → no lock, follow AC
        #   switch OFF → lock set, manual mode
        self.gpu_mode_switch.set_state(not r.manual)
        if r.manual:
            self.gpu_mode_row.set_subtitle(
                "Manual mode — dGPU stays in the state you chose below"
            )
        else:
            self.gpu_mode_row.set_subtitle(
                "Following AC state automatically"
            )
        # Buttons are always sensitive when the dGPU is present.
        # Pressing either one takes the user out of auto-mode (sets the
        # lock) and applies the requested state. To return to auto,
        # flip the switch above back on.
        self.btn_gpu_on.set_sensitive(
            r.gpu_present and r.gpu_control != "on"
        )
        self.btn_gpu_off.set_sensitive(
            r.gpu_present and r.gpu_control != "auto"
        )

        # Global switch (header)
        self.global_switch.set_state(r.enabled)

    def _find_nvidia_pci_addr(self) -> Optional[str]:
        for d in Path("/sys/bus/pci/devices").iterdir():
            try:
                if (d / "vendor").read_text().strip() != "0x10de":
                    continue
                cls = (d / "class").read_text().strip()
                if cls.startswith("0x03000") or cls.startswith("0x03020"):
                    return d.name
            except OSError:
                continue
        return None

    @staticmethod
    def _fmt_duration(minutes: float) -> str:
        if minutes < 0 or minutes > 60 * 24:
            return "—"
        h, m = divmod(int(minutes), 60)
        if h == 0:
            return f"{m} min"
        return f"{h} h {m:02d} min"

    def _infer_profile(self) -> str:
        """Best-effort profile inference when powerprofilesctl is unavailable
        (crashed or not installed). Map intel_pstate settings to a profile
        name so the UI does not show 'unknown' forever.
        """
        try:
            p = "/sys/devices/system/cpu/intel_pstate"
            no_turbo = open(f"{p}/no_turbo").read().strip()
            max_pct = open(f"{p}/max_perf_pct").read().strip()
        except OSError:
            return "unknown"
        if no_turbo == "1" or max_pct != "100":
            return "balanced"
        return "performance"

    def _do_action(self, action: str) -> None:
        if action == "gpu_on":
            ok, msg = gpu_set_power("on")
            self._toast("GPU → on" if ok else f"Failed: {msg}", ok)
        elif action == "gpu_off":
            ok, msg = gpu_set_power("auto")
            self._toast("GPU → auto" if ok else f"Failed: {msg}", ok)

    def _on_mode_toggle(self, _src, state: bool) -> bool:
        # state True = user wants auto (no lock, follow AC).
        # state False = user wants manual (set lock so AC does not override).
        if state:
            ok, msg = gpu_set_manual_lock(False)   # unlock
            if ok:
                # Re-assert the AC state right now so the GPU matches
                # AC without waiting for the next udev event.
                self._toast("Auto-switch re-enabled", True)
            else:
                self._toast(f"Failed: {msg}", False)
                self.gpu_mode_switch.set_state(False)
        else:
            ok, msg = gpu_set_manual_lock(True)    # lock
            if ok:
                self._toast("Manual mode — dGPU locked to your choice", True)
            else:
                self._toast(f"Failed: {msg}", False)
                self.gpu_mode_switch.set_state(True)
        return False

    def _on_global_toggle(self, _src, state: bool) -> bool:
        ok, msg = gpu_set_enabled(state)
        self._toast("Auto-switch ENABLED" if state and ok else
                    "Auto-switch DISABLED" if ok else
                    f"Failed: {msg}", ok)
        if not ok:
            # revert the switch
            self.global_switch.set_state(not state)
        return False

    def _toast(self, text: str, success: bool) -> None:
        t = Adw.Toast.new(text)
        t.set_timeout(3)
        if not success:
            t.set_priority(Adw.ToastPriority.HIGH)
        self._toast_overlay.add_toast(t)

    def _show_about(self) -> None:
        about = Adw.AboutWindow(
            transient_for=self,
            application_name="Linux Battery Saver",
            application_icon="battery",
            developer_name="pat",
            version=APP_VERSION,
            comments="Auto-toggle NVIDIA dGPU + system power profile on AC change.",
            website="https://github.com/blockman3063/Linux-Battery-Saver",
        )
        about.present()

    def _on_close_request(self, _win) -> bool:
        # Hide instead of quit so the poller keeps running and a tray-style
        # relaunch works. But this app has no tray, so we just stop polling.
        self._poller.stop()
        return False  # allow close


# ────────────────────────────────────────────────────────────────────
# Single-instance via UNIX socket
# ────────────────────────────────────────────────────────────────────

class SingleInstance:
    def __init__(self, on_show: Callable[[], None]) -> None:
        self._on_show = on_show
        self._sock: Optional[socket.socket] = None

    def try_acquire(self) -> bool:
        # Try to connect to existing instance
        if Path(SOCKET_PATH).exists():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.settimeout(1.0)
                    s.connect(SOCKET_PATH)
                    s.sendall(b"show\n")
                return False  # we connected, so we exit
            except (OSError, ConnectionRefusedError):
                try:
                    Path(SOCKET_PATH).unlink()
                except OSError:
                    pass
        # Bind
        try:
            Path(SOCKET_PATH).parent.mkdir(parents=True, exist_ok=True)
            self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._sock.bind(SOCKET_PATH)
            self._sock.listen(1)
            self._sock.settimeout(0.5)
        except OSError:
            return True  # can't bind, just run anyway
        threading.Thread(target=self._serve, daemon=True, name="gpa-ipc").start()
        return True

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self._sock.accept()
            except (OSError, socket.timeout):
                continue
            except Exception:
                return
            try:
                _ = conn.recv(64)
            except OSError:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass
            GLib.idle_add(self._on_show)


# ────────────────────────────────────────────────────────────────────
# Application
# ────────────────────────────────────────────────────────────────────


class App(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.window: Optional[MainWindow] = None
        self._start_hidden = "--hidden" in sys.argv

    def do_activate(self) -> None:
        if not self.window:
            self.window = MainWindow(self)
        if not self._start_hidden:
            self.window.present()

    def do_command_line(self, cmd: Gio.ApplicationCommandLine) -> int:
        opts = dict(cmd.get_options_dict().items() if False else [])
        args = cmd.get_arguments()
        if "show" in args or "--show" in args:
            self._start_hidden = False
        self.activate()
        return 0


def main() -> int:
    # Single-instance: a second `gpa` invocation asks the first to show
    def on_show():
        if app.window:
            app.window.present()

    si = SingleInstance(on_show=on_show)
    if not si.try_acquire():
        return 0  # another instance handled it

    app = App()
    if "--hidden" in sys.argv:
        app._start_hidden = True
    app.run(sys.argv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
