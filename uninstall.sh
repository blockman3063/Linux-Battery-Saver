#!/bin/bash
# uninstall.sh — remove all components of Linux Battery Saver.
#
# Removes files installed by install.sh but does NOT undo manual changes
# to /etc/fstab, modprobe blacklists, or any user-side autostart links.
set -eu
cd "$(dirname "$(readlink -f "$0")")"

PREFIX=${PREFIX:-/usr}
ETCDIR=${ETCDIR:-/etc}
INSTALL_LIB="$PREFIX/lib/gpu-power-switch"
INSTALL_BIN="$PREFIX/bin"
INSTALL_RULES="$ETCDIR/udev/rules.d"
INSTALL_SYSTEMD="$ETCDIR/systemd/system"
INSTALL_POLKIT="$PREFIX/share/polkit-1/actions"
INSTALL_APPS="$PREFIX/share/applications"
INSTALL_MODPROBE="/lib/modprobe.d"

log() { printf '\033[1;34m[uninstall]\033[0m %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E -- "$0" "$@"
    else
        echo "please run as root" >&2
        exit 1
    fi
fi

log "Stopping + disabling systemd service"
systemctl disable --now gpu-power-switch.service 2>/dev/null || true
rm -f "$INSTALL_SYSTEMD/gpu-power-switch.service"
systemctl daemon-reload

log "Removing udev rule"
rm -f "$INSTALL_RULES/99-gpu-power-switch.rules"
udevadm control --reload-rules

log "Removing CLI + GUI scripts"
rm -f "$INSTALL_LIB"/gpu-power-switch.sh
rm -f "$INSTALL_LIB"/gpu-power-switch-toggle
rm -f "$INSTALL_LIB"/gpu-power-switch-manual
rm -f "$INSTALL_BIN"/gpu-power-switch-gui
rm -rf "$INSTALL_LIB/gui"
rmdir "$INSTALL_LIB" 2>/dev/null || true

log "Removing polkit policy + .desktop entry"
rm -f "$INSTALL_POLKIT/org.linuxbatterysaver.policy"
rm -f "$INSTALL_APPS/linux-battery-saver.desktop"
# User-level autostart (created by install.sh or by you manually)
rm -f "$HOME/.config/autostart/linux-battery-saver.desktop"

log "Removing NVIDIA runtime-PM modprobe config"
rm -f "$INSTALL_MODPROBE/nvidia-runtimepm.conf"

log "Refreshing desktop + icon caches"
update-desktop-database "$INSTALL_APPS" 2>/dev/null || true
gtk-update-icon-cache -f "$PREFIX/share/icons/hicolor" 2>/dev/null || true

log "Done."
echo
echo "Note: any manual changes to /etc/fstab, modprobe blacklists,"
echo "or extra scripts in ~/.local/bin/ are NOT touched by uninstall."
