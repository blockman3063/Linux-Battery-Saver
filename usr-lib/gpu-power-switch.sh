#!/bin/bash
# gpu-power-switch.sh — toggle NVIDIA dGPU + system power profile on AC plug/unplug
# Invoked by:
#   1. /etc/udev/rules.d/99-gpu-power-switch.rules   (AC online change)
#   2. gpu-power-switch.service (boot, oneshot)
#
# Runs as root (udev default; systemd service runs as root).

set -u

# ---------- logging ----------
LOG_TAG="gpu-power-switch"
log()  { logger -t "$LOG_TAG" "$*"; }
info() { log "[INFO]  $*"; }
warn() { log "[WARN]  $*"; }
err()  { log "[ERROR] $*"; }

# ---------- locate tools ----------
PCICONTROL_BIN=""
for p in /sys/bus/pci/devices; do
    [ -d "$p" ] && PCICONTROL_BIN="$p" && break
done
[ -z "$PCICONTROL_BIN" ] && { err "no /sys/bus/pci/devices"; exit 1; }

# ---------- detect NVIDIA dGPU PCI address ----------
# Scan every PCI device whose vendor is 0x10de (NVIDIA). Skip if it is not a
# class 0x0300/0x0302 (3D/display) device — covers dedicated GPU only,
# not the bridge chip.
detect_nvidia_pci() {
    local dev vendor class ctrl
    for dev in "$PCICONTROL_BIN"/*; do
        [ -d "$dev" ] || continue
        vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
        class="$(cat  "$dev/class"  2>/dev/null || true)"
        case "$vendor" in
            0x10de) ;;   # NVIDIA
            *) continue ;;
        esac
        case "$class" in
            0x03000*|0x03020*) ;;  # VGA / 3D
            *) continue ;;
        esac
        ctrl="$dev/power/control"
        if [ -w "$ctrl" ] || [ -f "$ctrl" ]; then
            printf '%s\n' "$dev"
            return 0
        fi
    done
    return 1
}

NVIDIA_PCI="$(detect_nvidia_pci || true)"
if [ -z "$NVIDIA_PCI" ]; then
    warn "no writable NVIDIA PCI device found, skipping GPU toggle"
    NVIDIA_OK=0
else
    NVIDIA_OK=1
    info "NVIDIA dGPU: $NVIDIA_PCI"
fi

# ---------- determine current AC state ----------
# Globs every /sys/class/power_supply/AC*/online and ORs the results.
# Treats all AC* supplies equally (AC0, AC1, ADP0, …).
read_ac_state() {
    local f val online=0
    for f in /sys/class/power_supply/AC*/online; do
        [ -r "$f" ] || continue
        val="$(cat "$f" 2>/dev/null || true)"
        case "$val" in
            1) online=1 ;;
        esac
    done
    # Fallback: laptop-mode / named batteries exposing AC.
    if [ "$online" = 0 ]; then
        for f in /sys/class/power_supply/AC*/status; do
            [ -r "$f" ] || continue
            val="$(cat "$f" 2>/dev/null || true)"
            [ "$val" = "Charging" ] || [ "$val" = "Full" ] && online=1
        done
    fi
    return $((1 - online))   # 0 = on AC, 1 = on battery
}

if ! read_ac_state; then
    info "AC state: on battery"
    AC_ONLINE=0
else
    info "AC state: plugged in"
    AC_ONLINE=1
fi

# ---------- switch NVIDIA dGPU power state ----------
#   AC online  -> power/control = on      (wake)
#   on battery -> power/control = auto   (runtime-pm; suspends when idle)
set_gpu_power() {
    local mode="$1"
    local ctrl="$NVIDIA_PCI/power/control"
    [ "$NVIDIA_OK" = 1 ] || return 0
    [ -w "$ctrl" ] || { warn "$ctrl not writable"; return 0; }
    if printf '%s' "$mode" > "$ctrl" 2>/tmp/gpu-power-switch.err; then
        info "GPU power/control -> $mode"
    else
        err "GPU power/control write failed: $(cat /tmp/gpu-power-switch.err)"
    fi
    rm -f /tmp/gpu-power-switch.err
}

if [ "$AC_ONLINE" = 1 ]; then
    set_gpu_power on
else
    set_gpu_power auto
fi

# ---------- switch system power profile ----------
# Prefers power-profiles-daemon; falls back to TLP.
set_profile() {
    local target="$1"   # performance | balanced | power-saver

    if command -v powerprofilesctl >/dev/null 2>&1; then
        if powerprofilesctl set "$target" 2>/tmp/gpu-power-switch.err; then
            info "powerprofilesctl set $target"
            rm -f /tmp/gpu-power-switch.err
            return 0
        else
            warn "powerprofilesctl failed: $(cat /tmp/gpu-power-switch.err)"
            rm -f /tmp/gpu-power-switch.err
        fi
    fi

    if command -v tlp >/dev/null 2>&1; then
        local tlp_mode
        case "$target" in
            performance) tlp_mode=AC ;;
            balanced|power-saver) tlp_mode=BAT ;;
        esac
        if tlp "$tlp_mode" 2>/tmp/gpu-power-switch.err; then
            info "tlp $tlp_mode"
            rm -f /tmp/gpu-power-switch.err
            return 0
        else
            warn "tlp failed: $(cat /tmp/gpu-power-switch.err)"
            rm -f /tmp/gpu-power-switch.err
        fi
    fi

    warn "no power profile tool available (powerprofilesctl / tlp)"
    return 0
}

if [ "$AC_ONLINE" = 1 ]; then
    set_profile performance
else
    set_profile balanced
fi

exit 0