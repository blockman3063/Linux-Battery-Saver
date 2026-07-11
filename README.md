# Linux Battery Saver (gpu-power-switch)

A Linux power-management tool for **NVIDIA Optimus laptops**. When you plug in
the charger, it loads the NVIDIA driver, wakes the discrete GPU, switches to
the performance profile, and unlocks the CPU (turbo on, 100% max perf). When
you unplug, it unloads the NVIDIA driver (fully powers off the dGPU), switches
to balanced, and caps the CPU (turbo off, 30% max perf).

A real-time **GTK4 / libadwaita GUI** shows power draw, estimated battery
runtime, battery health, and lets you manually override the GPU state.

## Requirements

- Ubuntu (or any systemd distro)
- NVIDIA Optimus laptop with the proprietary NVIDIA driver installed
- One of (not both — they conflict):
  - `sudo apt install power-profiles-daemon`
  - `sudo apt install tlp`

## Quick install

```bash
git clone https://github.com/blockman3063/Linux-Battery-Saver.git
cd Linux-Battery-Saver
sudo make install
```

**That's it.** No manual configuration, no editing files, no AI agent needed.

After install:
- The systemd service runs at boot to set CPU / power profile
- The udev rule listens for AC plug/unplug events
- The GUI starts automatically at your next login
- Reboot once to clear any pre-existing NVIDIA driver state

## What `sudo make install` does

| What | Why |
|------|-----|
| Installs scripts + GUI to `/usr/lib/gpu-power-switch/` | Backend and frontend |
| Installs **udev rule** (`/etc/udev/rules.d/`) | Triggers on AC plug/unplug |
| Installs **systemd service** (`/etc/systemd/system/`) | Applies CPU profile at boot |
| Installs **polkit policy** | Lets the GUI call privileged actions without password |
| Installs **.desktop entry** | Shows in application menu + autostarts at login |
| Installs **modprobe config** (`/lib/modprobe.d/`) | Enables NVIDIA runtime-PM + blocks auto-load at boot |
| **Masks nvidia-persistenced** | Prevents it from loading NVIDIA at boot |
| **Enables + starts the service** | Active immediately, no reboot required |

After install, the GUI opens automatically at your next login. You can also
launch it from the application menu (**Linux Battery Saver**) or:

```bash
gpu-power-switch-gui            # show window
gpu-power-switch-gui --hidden   # start in background
```

## How it works

| Event | NVIDIA driver | System profile | CPU turbo | CPU max % |
|-------|---------------|----------------|-----------|-----------|
| 🔌 Plugged in | Loaded (`insmod`), power/control = `on` | `performance` | On | 100% |
| 🔋 On battery | Unloaded (`rmmod` + PCI remove), 0 W | `balanced` | Off | 30% |

- The NVIDIA driver is **not loaded at boot** (prime-select intel mode).
- On AC plug: the script does a PCI bus rescan, then loads `nvidia.ko` via `insmod`
  (bypassing modprobe blacklists), then `modprobe nvidia-uvm`.
- On battery: the script kills any process using `/dev/nvidia*` (including the
  GUI — it respawns automatically in 0.2 seconds), then unloads the driver and
  removes the PCI device from the bus for true D3cold power-off.
- The **cpufreq scaling governor** switches between `performance` (AC) and
  `powersave` (battery) alongside the turbo / max-perf-pct changes.

## GUI layout

**Power**
- **System** — total power. On battery: discharge rate. On AC: CPU+GPU+8W.
- **CPU** — package RAPL power (sum of all domains).
- **GPU** — nvidia-smi reading (when driver loaded) or `total−CPU` estimate
  (when driver unloaded).

**Battery**
- **Charge** — `% · Charging/Discharge X W · Health Y%`.
- **Estimated runtime** — `HH:MM:SS` from upower or own calculation.
- **Power profile** — current `powerprofilesctl` profile.

**NVIDIA dGPU**
- **PCI power control** — current `power/control` value.
- **Address** — PCI bus address.
- **Auto-switch on AC change** — toggle to lock/unlock manual mode.
- **Wake (on) / Off (auto)** — force GPU state.
- **GPU Power Mode** — switch between `intel` (iGPU-only) and `on-demand`
  (buttons trigger a 15-second auto-reboot).

## Uninstall

```bash
sudo make uninstall
```

This removes all installed files and unmask `nvidia-persistenced`.

## File layout in this repository

```
├── install.sh                     # one-shot installer
├── uninstall.sh                   # one-shot uninstaller
├── Makefile                       # thin wrapper (install / uninstall / test)
├── usr-lib/
│   ├── gpu-power-switch.sh        # main backend script
│   ├── gpu-power-switch-toggle    # flip global enabled flag
│   ├── gpu-power-switch-manual    # set GPU power + manual lock
│   └── gpu-power-switch-mode      # switch prime-select intel / on-demand
├── gui/
│   └── gpu-power-switch-gui.py    # GTK4 / libadwaita frontend
├── usr-bin/
│   └── gpu-power-switch-gui       # crash-proof launcher
├── udev/
│   └── 99-gpu-power-switch.rules  # AC online change trigger
├── systemd/
│   └── gpu-power-switch.service   # boot-time CPU/profile init
├── polkit/
│   └── org.linuxbatterysaver.policy
├── desktop/
│   └── linux-battery-saver.desktop
└── modprobe.d/
    ├── nvidia-runtimepm.conf       # NVreg_DynamicPowerManagement=0x02
    └── nvidia-off.conf             # block modprobe at boot (allow insmod)
```
