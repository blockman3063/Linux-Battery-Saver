# Linux Battery Saver (gpu-power-switch)

A small Linux power-management tool for **NVIDIA Optimus laptops**. When you
plug in the charger, it wakes the discrete GPU and switches the system to the
performance profile; when you unplug, it suspends the dGPU and switches back
to balanced. Includes a real-time **Adwaita GUI** for monitoring and manual
control.

Targets Ubuntu / any systemd distro with
[`power-profiles-daemon`](https://gitlab.freedesktop.org/hadess/power-profiles-daemon/)
or [`TLP`](https://linrunner.de/tlp/) installed.

## Features

| | CLI / udev | GUI (Adwaita) |
|---|---|---|
| Auto-toggle dGPU on AC change | ✓ | — |
| Auto-toggle power profile on AC change | ✓ | — |
| Real-time CPU / GPU / battery power draw | — | ✓ |
| Estimated runtime on battery | — | ✓ |
| Manual GPU wake / suspend buttons | — | ✓ |
| Global auto-switch enable / disable | — | ✓ |
| Manual-mode lock (override AC events) | — | ✓ |
| Single-instance (one window, many launches) | — | ✓ |

The GUI uses **GTK4 + libadwaita** and communicates with the privileged
backend through **polkit** (no password prompts after first install on a
single-user laptop).

## Install

```bash
sudo apt install power-profiles-daemon tlp
sudo make install
```

This installs:

| Source path | Install path |
|---|---|
| `udev/99-gpu-power-switch.rules` | `/etc/udev/rules.d/` |
| `usr-lib/gpu-power-switch.sh` | `/usr/lib/gpu-power-switch/` |
| `usr-lib/gpu-power-switch-toggle` | `/usr/lib/gpu-power-switch/` |
| `systemd/gpu-power-switch.service` | `/etc/systemd/system/` |
| `gui/gpu-power-switch-gui.py` | `/usr/lib/gpu-power-switch/gui/` |
| `usr-bin/gpu-power-switch-gui` | `/usr/bin/` |
| `polkit/org.linuxbatterysaver.policy` | `/usr/share/polkit-1/actions/` |
| `desktop/linux-battery-saver.desktop` | `/usr/share/applications/` |

Launch the GUI from the application menu (**Linux Battery Saver**) or:

```bash
gpu-power-switch-gui            # show window
gpu-power-switch-gui --hidden   # start hidden (use for autostart)
```

To autostart at login, copy the desktop file:

```bash
cp /usr/share/applications/linux-battery-saver.desktop ~/.config/autostart/
```

## How it works

### Backend (`gpu-power-switch.sh`)

- A **udev rule** runs the script on any `/sys/class/power_supply/AC*/online`
  change (covers `AC0`, `AC1`, `ADP0` …).
- The script scans `/sys/bus/pci/devices/` for an NVIDIA (vendor `0x10de`)
  3D-class device and toggles its `power/control` (`on` ↔ `auto`).
- It calls `powerprofilesctl set performance|balanced` (or `tlp ac|bat` as
  fallback).
- A **systemd oneshot** service runs the same script at boot, so the laptop
  boots into the correct state for its current power source.

### Global enable flag

`/etc/gpu-power-switch/enabled` controls whether the AC-driven switching
is active at all. The GUI's header-bar switch toggles this file. Default
content: missing or `1` = enabled. Set to `0` to disable AC automation
without uninstalling.

### Manual lock

`/var/lib/gpu-power-switch/manual.lock` blocks AC events. The GUI sets
this lock when you press a manual **Wake** / **Suspend** button. Switch
the "Auto-switch on AC change" row back on to release the lock.

### Frontend (`gpu-power-switch-gui.py`)

- **Adw.ApplicationWindow** with header bar containing the global switch.
- **Three groups:** Power, Battery, NVIDIA dGPU.
- Polls system state every 1.5 s on a worker thread (`threading.Thread`).
  Every 4th tick (≈6 s) it also runs `pkexec gpu-power-switch.sh status`
  to obtain RAPL CPU power (root-only sysfs).
- Privileged actions (set GPU power, set profile, toggle enabled flag)
  go through `pkexec` + the polkit policy.
- **Single-instance** via a UNIX socket in `$XDG_RUNTIME_DIR` — launching
  the .desktop again raises the existing window.

## Power data sources

| Field | Source | Privileged? |
|---|---|---|
| Battery discharge (W) | `power_now` or `current_now × voltage_now` | no (usually) |
| CPU package power (W) | `intel-rapl:*` `energy_uj` delta over 250 ms | **yes** |
| GPU power (W) | `nvidia-smi --query-gpu=power.draw` | no (nvidia-smi is setuid) |
| AC state | `power_supply/AC*/online` or `status` | no |
| Charge % | `power_supply/BAT*/capacity` | no |

If your kernel restricts RAPL (`0400 root:root` on `energy_uj` — common
on Ubuntu 22.04+), the CPU row will read `n/a (no RAPL)` and the value is
sourced from `pkexec` reading on your behalf.

## Limitations

- Single-user trust model — the polkit policy uses `allow_active=yes`.
  For a shared machine, edit `org.linuxbatterysaver.policy` to use
  `auth_admin_keep` so the user must enter the admin password.
- The script reads only `power_supply` AC supplies. A USB-C PD charger
  that reports itself as a `battery` is not detected.
- The GUI depends on GTK 4 + libadwaita (Ubuntu 22.04+ ships these).

## License

MIT.