# Linux Battery Saver (gpu-power-switch)

A small Linux power-management tool for **NVIDIA Optimus laptops**. When you
plug in the charger, it wakes the discrete GPU, switches the system to the
performance profile, and unlocks the CPU's full performance (turbo on, 100%
max perf). When you unplug, it suspends the dGPU, switches to balanced, and
caps the CPU at 30% with turbo disabled. A real-time **Adwaita GUI** shows
power draw, estimated runtime, and lets you override everything.

Targets Ubuntu / any systemd distro with
[`power-profiles-daemon`](https://gitlab.freedesktop.org/hadess/power-profiles-daemon/)
*or* [`TLP`](https://linrunner.de/tlp/) installed. The two are mutually
exclusive in Ubuntu's apt — pick one.

## What it does

| Event            | NVIDIA `power/control` | `powerprofilesctl` (or TLP) | intel_pstate (turbo / max %) |
| ---------------- | ---------------------- | --------------------------- | ---------------------------- |
| 🔌 Plugged in    | `on`                   | `performance`               | turbo **on**, 100%           |
| 🔋 On battery    | `auto`                 | `balanced`                  | turbo **off**, 30%           |

## Features

- AC-driven automatic switching via **udev**
- Boot-time state apply via **systemd oneshot** (After=power-profiles-daemon)
- Real-time **GTK4 / libadwaita** GUI:
  - Battery, CPU (RAPL), NVIDIA dGPU power draw, polled every 1.5 s
  - Estimated runtime on battery (Wh ÷ W × 60)
  - NVIDIA dGPU PCI address + manual Wake / Suspend buttons
  - Global auto-switch enable / disable (header-bar switch)
  - Manual-mode lock (override AC events, kept in `/var/lib/.../manual.lock`)
- Privileged actions go through **polkit** (`allow_active=yes` — no password
  prompts on a single-user laptop)
- Single-instance via UNIX socket at `$XDG_RUNTIME_DIR/gpu-power-switch.sock`
- NVIDIA runtime-PM via modprobe option `NVreg_DynamicPowerManagement=0x02`
- Idempotent: re-running on the same AC state is a no-op (no sysfs spam)

## Project layout

```
.
├── install.sh                            # one-shot installer (sudo)
├── uninstall.sh                          # one-shot uninstaller (sudo)
├── Makefile                              # thin wrapper around install/uninstall
├── usr-lib/
│   ├── gpu-power-switch.sh               # main backend
│   ├── gpu-power-switch-toggle           # flip /etc/gpu-power-switch/enabled
│   └── gpu-power-switch-manual           # GUI helper (set-power + lock)
├── gui/
│   └── gpu-power-switch-gui.py           # GTK4 / libadwaita frontend
├── usr-bin/
│   └── gpu-power-switch-gui              # /usr/bin/ launcher
├── udev/
│   └── 99-gpu-power-switch.rules         # AC online change trigger
├── systemd/
│   └── gpu-power-switch.service          # oneshot at boot
├── polkit/
│   └── org.linuxbatterysaver.policy      # polkit policy (3 actions)
├── desktop/
│   └── linux-battery-saver.desktop       # app menu entry + autostart
├── modprobe.d/
│   └── nvidia-runtimepm.conf             # NVreg_DynamicPowerManagement=0x02
└── old-config/                           # pre-existing personal scripts (backup)
```

## Install

```bash
# 1) one of these (NOT both — they conflict in apt):
sudo apt install power-profiles-daemon
# or
sudo apt install tlp

# 2) install everything
cd Linux-Battery-Saver
sudo make install           # or: sudo ./install.sh
```

Install paths (after `make install`):

| Source                          | Destination                                  |
| ------------------------------- | -------------------------------------------- |
| `usr-lib/gpu-power-switch.sh`   | `/usr/lib/gpu-power-switch/`                 |
| `usr-lib/gpu-power-switch-toggle` | `/usr/lib/gpu-power-switch/`               |
| `usr-lib/gpu-power-switch-manual` | `/usr/lib/gpu-power-switch/`               |
| `gui/gpu-power-switch-gui.py`   | `/usr/lib/gpu-power-switch/gui/`             |
| `usr-bin/gpu-power-switch-gui`  | `/usr/bin/gpu-power-switch-gui`              |
| `udev/99-gpu-power-switch.rules` | `/etc/udev/rules.d/99-gpu-power-switch.rules` |
| `systemd/gpu-power-switch.service` | `/etc/systemd/system/gpu-power-switch.service` |
| `polkit/org.linuxbatterysaver.policy` | `/usr/share/polkit-1/actions/org.linuxbatterysaver.policy` |
| `desktop/linux-battery-saver.desktop` | `/usr/share/applications/linux-battery-saver.desktop` |
| `modprobe.d/nvidia-runtimepm.conf` | `/lib/modprobe.d/nvidia-runtimepm.conf`    |

The NVIDIA runtime-PM modprobe option is read once at module load — it takes
effect after the next reboot (or `sudo modprobe -r nvidia && sudo modprobe nvidia`,
which will briefly blank the dGPU).

Launch the GUI from the application menu (**Linux Battery Saver**) or:

```bash
gpu-power-switch-gui            # show window
gpu-power-switch-gui --hidden   # start hidden (use for autostart)
```

To autostart at login:

```bash
cp /usr/share/applications/linux-battery-saver.desktop ~/.config/autostart/
```

## Uninstall

```bash
sudo make uninstall           # or: sudo ./uninstall.sh
```

Removes every file the installer created. Manual changes (e.g. `/etc/fstab`
additions, personal scripts in `~/.local/bin/`) are **not** touched.

## How it works

### udev

```
SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="/usr/lib/gpu-power-switch/gpu-power-switch.sh"
SUBSYSTEM=="power_supply", ATTR{online}=="1", RUN+="/usr/lib/gpu-power-switch/gpu-power-switch.sh"
```

Explicitly matches `0` or `1` (not `*`) so the rule fires **only** when
`online` actually changes. The script is also idempotent (it reads the
current state and short-circuits if it matches the desired state).

### Backend (`gpu-power-switch.sh`)

1. Read every `/sys/class/power_supply/AC*/online` and OR the results.
2. Scan `/sys/bus/pci/devices/` for a NVIDIA (vendor `0x10de`) 3D-class
   device — covers all PCI addresses, not just `0000:01:00.0`.
3. If the dGPU is already in the desired state, skip the write.
4. Write the new `power/control` (on / auto).
5. Set the system profile via `powerprofilesctl` (fallback: `tlp ac|battery`).
6. Set intel_pstate `no_turbo` + `max_perf_pct`.

A **systemd oneshot** service runs the same script at boot (after
`power-profiles-daemon` if present) so the laptop boots into the right
state for its current power source.

### Global enable flag

`/etc/gpu-power-switch/enabled` controls whether AC-driven switching
runs at all. The GUI's header-bar switch toggles this file. Default
content: missing or `1` = enabled. Set to `0` to disable AC automation
without uninstalling.

### Manual lock

`/var/lib/gpu-power-switch/manual.lock` blocks AC events. The GUI sets
this lock when the user toggles "Auto-switch on AC change" off, or when
they press a manual Wake / Suspend button. Clear it via the GUI to
re-enable AC auto-switching.

### Frontend (`gpu-power-switch-gui.py`)

- **Adw.ApplicationWindow** with header bar containing the global switch.
- Three groups: **Power** (system / CPU / GPU), **Battery** (charge %,
  estimated runtime, current profile), **NVIDIA dGPU** (PCI address,
  current `power/control`, manual buttons, manual lock switch).
- Polls every 1.5 s on a worker thread.
- First poll and every 4th poll after that go through `pkexec` to read
  RAPL (`energy_uj` is root-only) and battery state.
- Privileged writes (set GPU, set profile, flip enabled, set lock) go
  through `pkexec` + polkit.

## Power data sources

| Field             | Source                                              | Privileged? |
| ----------------- | --------------------------------------------------- | ----------- |
| Battery discharge | `power_now`, else `current_now × voltage_now`       | usually no  |
| CPU package power | `intel-rapl:*` `energy_uj` delta over 250 ms        | **yes**     |
| GPU power         | `nvidia-smi --query-gpu=power.draw`                 | no (suid)   |
| AC state          | `power_supply/AC*/online` or `status`               | no          |
| Charge %          | `power_supply/BAT*/capacity`                        | no          |
| CPU perf state    | `intel_pstate/no_turbo` + `max_perf_pct`            | **yes**     |

## Limitations

- Single-user trust model — polkit policy uses `allow_active=yes`. For
  a shared machine, edit `org.linuxbatterysaver.policy` to use
  `auth_admin_keep` (cached 5 min after first password).
- The script reads only `power_supply` AC supplies. A USB-C PD charger
  that reports itself as a `battery` is not detected.
- NVIDIA runtime-PM suspends the dGPU when no process has it open. The
  GNOME Wayland session uses `nvidia_drm` for display output, so the
  dGPU resumes immediately. For full power-down, disable `nvidia_drm`
  via `nvidia-drm.modeset=0` on the kernel command line.
- `power-profiles-daemon` and `tlp` are mutually exclusive in Ubuntu —
  install only one. The script supports both.

## License

MIT.
