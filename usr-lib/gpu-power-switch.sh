#!/bin/bash
# gpu-power-switch.sh — toggle NVIDIA dGPU + system power profile on AC plug/unplug
# Invoked by:
#   1. /etc/udev/rules.d/99-gpu-power-switch.rules   (AC online change)
#   2. gpu-power-switch.service                       (boot, oneshot)
#   3. GUI — `gpu-power-switch.sh set-power on|auto` (manual override)
#      Manual mode is *not* gated by the global enabled flag; the flag only
#      blocks automatic AC-driven switching.
#
# Runs as root (udev default; systemd service runs as root).

set -u

# ---------- paths ----------
CONFIG_DIR="/etc/gpu-power-switch"
STATE_DIR="/var/lib/gpu-power-switch"
ENABLED_FILE="$CONFIG_DIR/enabled"
LOCK_FILE="$STATE_DIR/manual.lock"   # when present, GUI is in manual control

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---------- logging ----------
LOG_TAG="gpu-power-switch"
log()  { logger -t "$LOG_TAG" "$*"; }
info() { log "[INFO]  $*"; }
warn() { log "[WARN]  $*"; }
err()  { log "[ERROR] $*"; }

# ---------- subcommands ----------
SUBCMD="ac"   # default: react to current AC state
if [ "${1:-}" = "set-power" ] || [ "${1:-}" = "set-profile" ] || [ "${1:-}" = "status" ]; then
    SUBCMD="$1"; shift || true
fi

# ---------- global enabled flag ----------
is_enabled() {
    # default: enabled (file missing or "1"/"true"/"yes")
    [ ! -f "$ENABLED_FILE" ] && return 0
    read -r val < "$ENABLED_FILE" 2>/dev/null || val=""
    case "${val,,}" in
        0|false|no|off|disabled) return 1 ;;
        *) return 0 ;;
    esac
}

# ---------- detect NVIDIA dGPU PCI address ----------
detect_nvidia_pci() {
    local dev vendor class
    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev" ] || continue
        vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
        class="$(cat  "$dev/class"  2>/dev/null || true)"
        case "$vendor" in
            0x10de) ;;
            *) continue ;;
        esac
        case "$class" in
            0x03000*|0x03020*) ;;
            *) continue ;;
        esac
        if [ -w "$dev/power/control" ] || [ -f "$dev/power/control" ]; then
            printf '%s\n' "$dev"
            return 0
        fi
    done
    return 1
}

NVIDIA_PCI="$(detect_nvidia_pci || true)"
if [ -z "$NVIDIA_PCI" ]; then
    warn "no writable NVIDIA PCI device found"
    NVIDIA_OK=0
else
    NVIDIA_OK=1
    info "NVIDIA dGPU: $NVIDIA_PCI"
fi

# ---------- read AC state ----------
read_ac_state() {
    local f val online=0
    for f in /sys/class/power_supply/AC*/online; do
        [ -r "$f" ] || continue
        val="$(cat "$f" 2>/dev/null || true)"
        [ "$val" = "1" ] && online=1
    done
    if [ "$online" = 0 ]; then
        for f in /sys/class/power_supply/AC*/status; do
            [ -r "$f" ] || continue
            val="$(cat "$f" 2>/dev/null || true)"
            [ "$val" = "Charging" ] || [ "$val" = "Full" ] && online=1
        done
    fi
    return $((1 - online))
}

# ---------- GPU power ----------
set_gpu_power() {
    local mode="$1"
    [ "$NVIDIA_OK" = 1 ] || return 0
    local ctrl="$NVIDIA_PCI/power/control"
    [ -w "$ctrl" ] || { warn "$ctrl not writable"; return 0; }
    if printf '%s' "$mode" > "$ctrl" 2>/tmp/gpu-power-switch.err; then
        info "GPU power/control -> $mode"
    else
        err "GPU power/control write failed: $(cat /tmp/gpu-power-switch.err)"
    fi
    rm -f /tmp/gpu-power-switch.err
}

# ---------- power profile ----------
set_profile() {
    local target="$1"
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
            performance)  tlp_mode=AC ;;
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

# ---------- subcommand: status (used by GUI) ----------
if [ "$SUBCMD" = "status" ]; then
    read_ac_state; AC_ONLINE=$((1 - $?))
    GPU_NOW=""
    if [ "$NVIDIA_OK" = 1 ]; then
        GPU_NOW="$(cat "$NVIDIA_PCI/power/control" 2>/dev/null || echo unknown)"
    fi
    PROFILE_NOW="$(powerprofilesctl get 2>/dev/null || echo unknown)"
    ENABLED_STR=$(is_enabled && echo true || echo false)
    MANUAL_STR=$([ -f "$LOCK_FILE" ] && echo true || echo false)
    RAPL_W=""
    BAT_W=""
    BAT_PCT=""
    # RAPL package power
    for d in /sys/class/powercap/intel-rapl*; do
        [ -r "$d/name" ] || continue
        n="$(cat "$d/name" 2>/dev/null)" || continue
        case "$n" in
            package-*) ;;
            *) continue ;;
        esac
        [ -r "$d/energy_uj" ] || continue
        a="$(cat "$d/energy_uj")" 2>/dev/null || continue
        sleep 0.25
        b="$(cat "$d/energy_uj")" 2>/dev/null || continue
        [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] || continue
        w=$(awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f",(b-a)/1e6/0.25}')
        RAPL_W="${RAPL_W:+$RAPL_W,}$w"
    done
    # Battery
    for b in /sys/class/power_supply/BAT*; do
        [ -d "$b" ] || continue
        if [ -r "$b/power_now" ]; then
            pw=$(cat "$b/power_now" 2>/dev/null)
            [ -n "$pw" ] && BAT_W="$(awk -v x="$pw" 'BEGIN{printf "%.2f",x/1e6}')"
        fi
        cp=$(cat "$b/capacity" 2>/dev/null)
        [ -n "$cp" ] && BAT_PCT="$cp"
        break
    done
    cat <<EOF
ac_online=$AC_ONLINE
gpu_control=$GPU_NOW
gpu_present=$NVIDIA_OK
profile=$PROFILE_NOW
enabled=$ENABLED_STR
manual=$MANUAL_STR
enabled_file=$ENABLED_FILE
nvidia_pci=$NVIDIA_PCI
rapl_w=$RAPL_W
bat_w=$BAT_W
bat_pct=$BAT_PCT
EOF
    exit 0
fi

# ---------- subcommand: set-power (manual override, runs as root via pkexec/policy) ----------
if [ "$SUBCMD" = "set-power" ]; then
    target="${1:-}"
    case "$target" in
        on|auto) ;;
        *) err "set-power: expected on|auto (got '$target')"; exit 2 ;;
    esac
    set_gpu_power "$target"
    # mark manual control so udev does not immediately override the user's choice
    if [ "$target" = "on" ]; then touch "$LOCK_FILE"; else rm -f "$LOCK_FILE"; fi
    exit 0
fi

# ---------- subcommand: set-profile ----------
if [ "$SUBCMD" = "set-profile" ]; then
    target="${1:-}"
    case "$target" in
        performance|balanced|power-saver) ;;
        *) err "set-profile: expected performance|balanced|power-saver (got '$target')"; exit 2 ;;
    esac
    set_profile "$target"
    exit 0
fi

# ---------- default subcommand: ac ----------
# Honour the global enabled flag. If disabled, do nothing for AC events.
if ! is_enabled; then
    info "global switch is OFF, skipping AC-driven change"
    exit 0
fi

# If the user is in manual mode, do not fight their choice; just record state.
if [ -f "$LOCK_FILE" ]; then
    info "manual mode lock present, skipping AC-driven change"
    exit 0
fi

if ! read_ac_state; then
    info "AC state: on battery"
    AC_ONLINE=0
else
    info "AC state: plugged in"
    AC_ONLINE=1
fi

if [ "$AC_ONLINE" = 1 ]; then
    set_gpu_power on
    set_profile performance
else
    set_gpu_power auto
    set_profile balanced
fi

exit 0