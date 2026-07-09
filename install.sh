#!/bin/bash
# install.sh — install all components of Linux Battery Saver
#
# Layout (project root):
#   usr-lib/gpu-power-switch.sh         → /usr/lib/gpu-power-switch/
#   usr-lib/gpu-power-switch-toggle    → /usr/lib/gpu-power-switch/
#   usr-lib/gpu-power-switch-manual    → /usr/lib/gpu-power-switch/
#   usr-lib/gpu-power-switch-status    → /usr/lib/gpu-power-switch/  (helper)
#   gui/gpu-power-switch-gui.py        → /usr/lib/gpu-power-switch/gui/
#   usr-bin/gpu-power-switch-gui       → /usr/bin/
#   udev/99-gpu-power-switch.rules     → /etc/udev/rules.d/
#   systemd/gpu-power-switch.service   → /etc/systemd/system/
#   polkit/org.linuxbatterysaver.policy→ /usr/share/polkit-1/actions/
#   desktop/linux-battery-saver.desktop→ /usr/share/applications/
#   modprobe.d/nvidia-runtimepm.conf   → /lib/modprobe.d/
#
# Idempotent: re-running updates files in place and reloads daemons.
# Requires: sudo (we use it once for the privileged operations).
set -eu
cd "$(dirname "$(readlink -f "$0")")"

PREFIX=${PREFIX:-/usr}
ETCDIR=${ETCDIR:-/etc}
SRC_LIB="usr-lib"
SRC_BIN="usr-bin"
SRC_GUI="gui"

INSTALL_LIB="$PREFIX/lib/gpu-power-switch"
INSTALL_BIN="$PREFIX/bin"
INSTALL_RULES="$ETCDIR/udev/rules.d"
INSTALL_SYSTEMD="$ETCDIR/systemd/system"
INSTALL_POLKIT="$PREFIX/share/polkit-1/actions"
INSTALL_APPS="$PREFIX/share/applications"
INSTALL_MODPROBE="/lib/modprobe.d"

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

# Need root for everything
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E -- "$0" "$@"
    else
        die "please run as root"
    fi
fi

log "Installing CLI scripts to $INSTALL_LIB"
install -d -m 755 "$INSTALL_LIB" "$INSTALL_LIB/gui"
for f in gpu-power-switch.sh gpu-power-switch-toggle gpu-power-switch-manual; do
    install -m 755 "$SRC_LIB/$f" "$INSTALL_LIB/$f"
done

log "Installing GUI module + launcher"
install -m 755 "$SRC_GUI/gpu-power-switch-gui.py" "$INSTALL_LIB/gui/gpu-power-switch-gui.py"
install -d -m 755 "$INSTALL_BIN"
install -m 755 "$SRC_BIN/gpu-power-switch-gui" "$INSTALL_BIN/gpu-power-switch-gui"

log "Installing udev rule + systemd unit"
install -d -m 755 "$INSTALL_RULES" "$INSTALL_SYSTEMD"
install -m 644 udev/99-gpu-power-switch.rules "$INSTALL_RULES/99-gpu-power-switch.rules"
install -m 644 systemd/gpu-power-switch.service "$INSTALL_SYSTEMD/gpu-power-switch.service"
udevadm control --reload-rules
# Reload + re-trigger only the power_supply uevents to apply the new rule
udevadm trigger --subsystem-match=power_supply --action=change

# If a previous (incompatible) version is still installed under the old
# filenames, neutralize it so we do not race the new rule.
if [ -f "$INSTALL_RULES/99-power-profile.rules" ]; then
    warn "old /etc/udev/rules.d/99-power-profile.rules detected — disabling"
    mv "$INSTALL_RULES/99-power-profile.rules" "$INSTALL_RULES/99-power-profile.rules.disabled"
    udevadm control --reload-rules
fi
if [ -f "$INSTALL_SYSTEMD/power-profile-switch.service" ]; then
    warn "old systemd unit detected — disabling"
    systemctl disable --now power-profile-switch.service 2>/dev/null || true
    mv "$INSTALL_SYSTEMD/power-profile-switch.service" "$INSTALL_SYSTEMD/power-profile-switch.service.disabled"
    systemctl daemon-reload
fi

log "Installing polkit policy + .desktop entry"
install -d -m 755 "$INSTALL_POLKIT" "$INSTALL_APPS"
install -m 644 polkit/org.linuxbatterysaver.policy "$INSTALL_POLKIT/org.linuxbatterysaver.policy"
install -m 644 desktop/linux-battery-saver.desktop "$INSTALL_APPS/linux-battery-saver.desktop"

log "Installing NVIDIA runtime-PM modprobe config"
install -d -m 755 "$INSTALL_MODPROBE"
install -m 644 modprobe.d/nvidia-runtimepm.conf "$INSTALL_MODPROBE/nvidia-runtimepm.conf"

log "Enabling + starting systemd service"
systemctl daemon-reload
systemctl enable --now gpu-power-switch.service

log "Refreshing desktop + icon caches"
update-desktop-database "$INSTALL_APPS" 2>/dev/null || true
gtk-update-icon-cache -f "$PREFIX/share/icons/hicolor" 2>/dev/null || true

log "Done."
echo
echo "Try the GUI:"
echo "    gpu-power-switch-gui"
echo
echo "Or watch the next AC change:"
echo "    journalctl -t gpu-power-switch -f"
echo
echo "Note: NVIDIA runtime-PM setting takes effect after the next reboot"
echo "      (it is a module-load parameter)."
