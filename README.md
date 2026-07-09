# Linux Battery Saver (gpu-power-switch)

`gpu-power-switch` — automatically turns the **NVIDIA discrete GPU** on/off and
switches the system **power profile** when you plug/unplug the charger on a
laptop with NVIDIA Optimus.

It is meant for Ubuntu (or any systemd distro) with both
[`power-profiles-daemon`](https://gitlab.freedesktop.org/hadess/power-profiles-daemon/)
and [`TLP`](https://linrunner.de/tlp/) available. Designed for machines where
the dGPU is **not wired to a display** (pure compute / CUDA workloads).

## What it does

| Event            | NVIDIA PCI `power/control` | Power profile (preferred) | Fallback (TLP) |
| ---------------- | -------------------------- | ------------------------- | -------------- |
| 🔌 Plugged in    | `on`                       | `performance`             | `tlp ac`       |
| 🔋 On battery    | `auto`                     | `balanced`                | `tlp bat`      |

`auto` lets the kernel runtime-PM the dGPU, so it suspends when no process
holds it open — extending battery life on Optimus laptops.

## Files

```
udev/99-gpu-power-switch.rules        # AC online change -> run script
usr-lib/gpu-power-switch.sh           # the brain (auto-detects NVIDIA PCI)
systemd/gpu-power-switch.service      # oneshot at boot, after ppd
Makefile                             # install / uninstall
```

When installed:

```
/etc/udev/rules.d/99-gpu-power-switch.rules
/usr/lib/gpu-power-switch/gpu-power-switch.sh
/etc/systemd/system/gpu-power-switch.service
```

## Install

```bash
sudo apt install power-profiles-daemon tlp   # if not already
sudo make install
```

After install, plug/unplug the AC adapter — the dGPU and power profile should
flip. Check logs:

```bash
journalctl -t gpu-power-switch -f
```

## Uninstall

```bash
sudo make uninstall
```

## How it works

1. **udev** fires the script every time any `/sys/class/power_supply/AC*/online`
   attribute changes. It is not just `AC` — many laptops expose `AC0`, `AC1`,
   or `ADP0`; this script globs all of them and ORs the result.
2. The script scans `/sys/bus/pci/devices/` for a device whose `vendor` is
   `0x10de` (NVIDIA) and `class` is `0x0300xx` / `0x0302xx` (VGA / 3D).
   This way it works regardless of the PCI address (`0000:01:00.0` is the
   usual spot, but not guaranteed).
3. Writes `on` / `auto` to that device's `power/control`.
4. Calls `powerprofilesctl set performance|balanced`. If that fails or is
   missing, falls back to `tlp ac` / `tlp bat`.
5. Errors only go to `logger` (visible via `journalctl -t gpu-power-switch`);
   they never block the udev event.

A **systemd oneshot** service runs the same script at boot, so the laptop
boots into the right state for its current power source without waiting for
the first AC change event.

## Limitations

- Requires root (udev and systemd both run scripts as root — fine).
- Assumes the dGPU has runtime-PM support. Most NVIDIA consumer GPUs do
  *not* suspend cleanly under `auto` on older kernels; if yours reboots or
  hangs on battery, set `NVIDIA_OK=0` path or blacklist the dGPU driver
  (`prime-select on-demand` / `bbswitch` instead).
- The script reads only `power_supply` AC supplies. A USB-C PD charger that
  reports itself as a `battery` will not be detected.

## License

MIT.