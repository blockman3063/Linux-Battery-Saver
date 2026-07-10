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
    local dev vendor class driver drvname
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
        driver="$(readlink "$dev/driver" 2>/dev/null || true)"
        drvname="$(basename "$driver" 2>/dev/null || true)"
        [ "$drvname" = "nvidia" ] || continue
        if [ -e "$dev/power/control" ]; then
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
    [ -e "$ctrl" ] || { warn "$ctrl does not exist"; return 0; }
    # We cannot pre-test with [ -w ] because sysfs is virtual; just try.
    local current
    current="$(cat "$ctrl" 2>/dev/null || echo unknown)"
    info "GPU power/control current=$current requested=$mode"
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
            performance)  tlp_mode=ac ;;
            balanced|power-saver) tlp_mode=bat ;;
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

# ---------- CPU performance (intel_pstate) ----------
# On battery: disable turbo + cap max perf at 30%  → longer runtime
# On AC:      enable turbo + raise cap to 100%   → full performance
# Only active when the intel_pstate driver reports "active" (i.e. the
# CPU is actually using pstate scaling). On older systems with the
# generic acpi-cpufreq driver this is a no-op.
set_cpu_perf() {
    local target="$1"   # performance | balanced
    local no_turbo max_pct
    case "$target" in
        performance) no_turbo=0; max_pct=100 ;;
        balanced)    no_turbo=1; max_pct=30  ;;
        *) return 0 ;;
    esac
    local pstate_dir="/sys/devices/system/cpu/intel_pstate"
    [ -d "$pstate_dir" ] || { info "intel_pstate not available, skipping CPU perf"; return 0; }
    [ "$(cat "$pstate_dir/status" 2>/dev/null)" = "active" ] || {
        info "intel_pstate driver not active, skipping CPU perf"; return 0;
    }
    if [ -w "$pstate_dir/no_turbo" ]; then
        local cur
        cur="$(cat "$pstate_dir/no_turbo" 2>/dev/null || echo ?)"
        if [ "$cur" = "$no_turbo" ]; then
            info "intel_pstate no_turbo already $cur"
        elif printf '%s' "$no_turbo" > "$pstate_dir/no_turbo" 2>/tmp/gpu-power-switch.err; then
            info "intel_pstate no_turbo -> $no_turbo"
        else
            warn "no_turbo write failed: $(cat /tmp/gpu-power-switch.err)"
        fi
    fi
    if [ -w "$pstate_dir/max_perf_pct" ]; then
        local cur_pct
        cur_pct="$(cat "$pstate_dir/max_perf_pct" 2>/dev/null || echo ?)"
        if [ "$cur_pct" = "$max_pct" ]; then
            info "intel_pstate max_perf_pct already $cur_pct"
        elif printf '%s' "$max_pct" > "$pstate_dir/max_perf_pct" 2>/tmp/gpu-power-switch.err; then
            info "intel_pstate max_perf_pct -> $max_pct"
        else
            warn "max_perf_pct write failed: $(cat /tmp/gpu-power-switch.err)"
        fi
    fi
    rm -f /tmp/gpu-power-switch.err
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
    BAT_ENERGY_WH=""
    BAT_ENERGY_FULL_WH=""
    BAT_VOLTAGE=""
    BAT_TIME=""
    # RAPL package power — best-effort; if not readable, we just leave
    # the value empty so the GUI can show "n/a" instead of erroring.
    for d in /sys/class/powercap/intel-rapl*; do
        [ -r "$d/name" ] || continue
        n="$(cat "$d/name" 2>/dev/null)" || continue
        case "$n" in
            package-*) ;;
            *) continue ;;
        esac
        [ -r "$d/energy_uj" ] || continue
        a="$(cat "$d/energy_uj" 2>/dev/null)" || continue
        sleep 0.25
        b="$(cat "$d/energy_uj" 2>/dev/null)" || continue
        [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] || continue
        w=$(awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f",(b-a)/1e6/0.25}')
        RAPL_W="${RAPL_W:+$RAPL_W,}$w"
    done
    # Battery — prefer UPower (it normalizes Wh / voltage from whatever
    # the kernel driver exposes) and fall back to sysfs.
    if command -v upower >/dev/null 2>&1; then
        up_out="$(upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null || true)"
        # Strip leading whitespace from each line so awk field-1
        # comparisons work despite upower's indented output.
        up_clean="$(printf '%s\n' "$up_out" | sed 's/^[[:space:]]*//')"
        # upower output is "key:    value unit", so the first ':'
        # is the field separator. Compare against the key with the
        # trailing ':' stripped (awk's -F eats the separator).
        for k in 'energy' 'energy-rate' 'energy-full' 'voltage' 'time to empty' 'time to full'; do
            v="$(printf '%s\n' "$up_clean" | awk -F': *' -v key="$k" '$1 == key { print $2; exit }')"
            case "$k" in
                energy)          [ -n "$v" ] && BAT_ENERGY_WH="${v% Wh}" ;;
                energy-full)     [ -n "$v" ] && BAT_ENERGY_FULL_WH="${v% Wh}" ;;
                energy-rate)     [ -n "$v" ] && BAT_W="${v% W}" ;;
                voltage)         [ -n "$v" ] && BAT_VOLTAGE="${v% V}" ;;
                'time to empty') [ -n "$v" ] && BAT_TIME="$v" ;;
                'time to full')  [ -n "$v" ] && [ -z "$BAT_TIME" ] && BAT_TIME="$v" ;;
            esac
        done
    fi
    # sysfs fallback for fields UPower may not show
    for b in /sys/class/power_supply/BAT*; do
        [ -d "$b" ] || continue
        if [ -r "$b/capacity" ]; then
            cp=$(cat "$b/capacity" 2>/dev/null)
            [ -n "$cp" ] && BAT_PCT="$cp"
        fi
        # charge-based batteries (µAh) + design voltage → Wh estimate
        # Wh = Ah × V. µAh / 1e6 = Ah. µV / 1e6 = V. Wh = c*v/1e12.
        if [ -z "$BAT_ENERGY_WH" ] && [ -r "$b/charge_now" ] && [ -r "$b/charge_full_design" ]; then
            cn=$(cat "$b/charge_now" 2>/dev/null)
            cf=$(cat "$b/charge_full_design" 2>/dev/null)
            vd=$(cat "$b/voltage_min_design" 2>/dev/null)
            if [ -n "$cn" ] && [ -n "$cf" ] && [ -n "$vd" ] && [ "$cf" -gt 0 ]; then
                now_wh=$(awk -v c="$cn" -v v="$vd" 'BEGIN{printf "%.2f", c*v/1e12}')
                full_wh=$(awk -v c="$cf" -v v="$vd" 'BEGIN{printf "%.2f", c*v/1e12}')
                [ -z "$BAT_ENERGY_WH" ] && BAT_ENERGY_WH="$now_wh"
                [ -z "$BAT_ENERGY_FULL_WH" ] && BAT_ENERGY_FULL_WH="$full_wh"
            fi
        fi
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
bat_energy_wh=$BAT_ENERGY_WH
bat_energy_full_wh=$BAT_ENERGY_FULL_WH
bat_voltage=$BAT_VOLTAGE
bat_time=$BAT_TIME
cpu_no_turbo=$([ -r /sys/devices/system/cpu/intel_pstate/no_turbo ] && cat /sys/devices/system/cpu/intel_pstate/no_turbo || echo n/a)
cpu_max_perf_pct=$([ -r /sys/devices/system/cpu/intel_pstate/max_perf_pct ] && cat /sys/devices/system/cpu/intel_pstate/max_perf_pct || echo n/a)
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
    # Note: we do NOT touch the manual lock here. The lock is managed
    # exclusively by the GUI's "Auto-switch on AC change" switch — see
    # _on_manual_toggle. set-power just changes the GPU state and lets
    # the GUI re-enable auto-mode when the user is ready.
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

# Driver load/unload: on prime-select intel, nvidia modules are
# blacklisted and must be loaded via insmod. This allows the dGPU to
# be completely powered off on battery and reactivated on AC without
# a reboot.
NVIDIA_BASE="/lib/modules/$(uname -r)/kernel/nvidia-595-open"
NVIDIA_KO="$NVIDIA_BASE/nvidia.ko"

load_nvidia_driver() {
    if lsmod | grep -q '^nvidia '; then
        info "nvidia driver already loaded"
        return 0
    fi
    if [ -f "$NVIDIA_KO" ]; then
        info "loading nvidia driver via insmod"
        insmod "$NVIDIA_KO" NVreg_DynamicPowerManagement=0x02 2>/tmp/gpu-power-switch.err
        modprobe nvidia-uvm 2>/dev/null || true
    else
        warn "nvidia.ko not found at $NVIDIA_KO"
        return 1
    fi
    # Re-detect now that the driver is loaded
    NVIDIA_PCI="$(detect_nvidia_pci || true)"
    if [ -n "$NVIDIA_PCI" ]; then
        NVIDIA_OK=1
        info "NVIDIA dGPU now available: $NVIDIA_PCI"
    else
        NVIDIA_OK=0
        warn "nvidia driver loaded but PCI device not found"
    fi
}

unload_nvidia_driver() {
    if ! lsmod | grep -q '^nvidia '; then
        info "nvidia driver not loaded, nothing to unload"
        return 0
    fi
    info "unloading nvidia driver"
    # Kill userspace processes holding nvidia devices open
    fuser -k /dev/nvidia* 2>/dev/null || true
    sleep 0.5
    modprobe -r nvidia-uvm 2>/dev/null || true
    modprobe -r nvidia-drm 2>/dev/null || true
    modprobe -r nvidia-modeset 2>/dev/null || true
    if rmmod nvidia 2>/tmp/gpu-power-switch.err; then
        info "nvidia driver unloaded"
    else
        err "rmmod nvidia failed: $(cat /tmp/gpu-power-switch.err)"
    fi
    NVIDIA_OK=0
    NVIDIA_PCI=""
    rm -f /tmp/gpu-power-switch.err
}

# Determine desired GPU / profile / CPU state
DESIRED_GPU="auto"
DESIRED_PROFILE="balanced"
if [ "$AC_ONLINE" = 1 ]; then
    DESIRED_GPU="on"
    DESIRED_PROFILE="performance"
    load_nvidia_driver
else
    # On battery: set GPU to auto first, then unload the driver
    unload_nvidia_driver
fi

# Idempotency: skip the write if the GPU is already in the desired state.
if [ "$NVIDIA_OK" = 1 ] && [ -r "$NVIDIA_PCI/power/control" ]; then
    cur="$(cat "$NVIDIA_PCI/power/control" 2>/dev/null || echo)"
    if [ "$cur" = "$DESIRED_GPU" ]; then
        info "GPU already in $cur, skipping"
        DESIRED_GPU=""
    fi
fi

if [ "$NVIDIA_OK" = 1 ] && [ -n "$DESIRED_GPU" ]; then
    set_gpu_power "$DESIRED_GPU"
fi
set_profile "$DESIRED_PROFILE"
set_cpu_perf  "$DESIRED_PROFILE"

exit 0