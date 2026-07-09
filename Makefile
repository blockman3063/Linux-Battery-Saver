# gpu-power-switch — Makefile
#
# Targets:
#   make install       — install everything (scripts, udev, systemd, GUI, polkit, .desktop)
#   make uninstall     — remove every installed file
#   make install-cli   — CLI only (no GUI / no polkit / no .desktop)
#   make install-gui   — GUI + polkit + .desktop (also installs CLI)
#   make dry-run       — show what install would do, without touching the system
#   make test          — run syntax / smoke tests
#
# Install paths follow Debian/Ubuntu conventions.

PREFIX       ?= /usr
ETCDIR       ?= /etc
DATADIR      ?= /usr/share

UDEV_RULESDIR = $(ETCDIR)/udev/rules.d
LIBDIR       = $(PREFIX)/lib/gpu-power-switch
SYSTEMD_DIR  = $(ETCDIR)/systemd/system
BINDIR       = $(PREFIX)/bin
POLKITDIR    = $(DATADIR)/polkit-1/actions
APPSDIR      = $(DATADIR)/applications

UDEV_FILE    = $(UDEV_RULESDIR)/99-gpu-power-switch.rules
SCRIPT_FILE  = $(LIBDIR)/gpu-power-switch.sh
TOGGLE_FILE  = $(LIBDIR)/gpu-power-switch-toggle
GUI_DIR      = $(LIBDIR)/gui
GUI_BIN      = $(BINDIR)/gpu-power-switch-gui
SERVICE_FILE = $(SYSTEMD_DIR)/gpu-power-switch.service
POLICY_FILE  = $(POLKITDIR)/org.linuxbatterysaver.policy
DESKTOP_FILE = $(APPSDIR)/linux-battery-saver.desktop

SRC_UDEV     = udev/99-gpu-power-switch.rules
SRC_SCRIPT   = usr-lib/gpu-power-switch.sh
SRC_TOGGLE   = usr-lib/gpu-power-switch-toggle
SRC_GUI_LAUNCHER = usr-bin/gpu-power-switch-gui
SRC_GUI_PY  = gui/gpu-power-switch-gui.py
SRC_SERVICE  = systemd/gpu-power-switch.service
SRC_POLICY   = polkit/org.linuxbatterysaver.policy
SRC_DESKTOP  = desktop/linux-battery-saver.desktop

.PHONY: install uninstall install-cli install-gui dry-run test reload-udev enable-service

install: install-cli install-gui
	@echo "Done. Launch 'Linux Battery Saver' from the apps menu, or run 'gpu-power-switch-gui'."

install-cli:
	@echo ">>> [CLI] installing scripts + udev + systemd"
	install -d -m 755 "$(LIBDIR)" "$(UDEV_RULESDIR)" "$(SYSTEMD_DIR)"
	install -m 644 "$(SRC_UDEV)"    "$(UDEV_FILE)"
	install -m 755 "$(SRC_SCRIPT)"  "$(SCRIPT_FILE)"
	install -m 755 "$(SRC_TOGGLE)"  "$(TOGGLE_FILE)"
	install -m 644 "$(SRC_SERVICE)" "$(SERVICE_FILE)"
	udevadm control --reload-rules
	udevadm trigger --subsystem-match=power_supply
	-systemctl daemon-reload
	-systemctl enable gpu-power-switch.service
	-systemctl start  gpu-power-switch.service
	@echo ">>> [CLI] OK. Check 'journalctl -t gpu-power-switch -f' on next AC change."

install-gui:
	@echo ">>> [GUI] installing python app, polkit policy, .desktop, autostart"
	install -d -m 755 "$(GUI_DIR)" "$(BINDIR)" "$(POLKITDIR)" "$(APPSDIR)"
	install -m 755 "$(SRC_GUI_PY)"      "$(GUI_DIR)/gpu-power-switch-gui.py"
	install -m 755 "$(SRC_GUI_LAUNCHER)" "$(GUI_BIN)"
	install -m 644 "$(SRC_POLICY)"       "$(POLICY_FILE)"
	install -m 644 "$(SRC_DESKTOP)"      "$(DESKTOP_FILE)"
	@echo ">>> [GUI] OK. Launch with: gpu-power-switch-gui"
	@echo ">>> [GUI] Autostart: copy desktop file into ~/.config/autostart/ if desired."

uninstall:
	@echo ">>> Disabling + removing systemd service"
	-systemctl disable --now gpu-power-switch.service
	rm -f "$(SERVICE_FILE)"
	-systemctl daemon-reload
	@echo ">>> Removing scripts + udev rule"
	rm -f "$(SCRIPT_FILE)" "$(TOGGLE_FILE)"
	rm -rf "$(GUI_DIR)"
	rmdir "$(LIBDIR)" 2>/dev/null || true
	rm -f "$(UDEV_FILE)" "$(GUI_BIN)" "$(POLICY_FILE)" "$(DESKTOP_FILE)"
	rm -f ~/.config/autostart/linux-battery-saver.desktop
	udevadm control --reload-rules
	@echo "Done."

dry-run:
	@echo "Would install CLI:"
	@echo "  $(SRC_UDEV)    -> $(UDEV_FILE)"
	@echo "  $(SRC_SCRIPT)  -> $(SCRIPT_FILE)"
	@echo "  $(SRC_TOGGLE)  -> $(TOGGLE_FILE)"
	@echo "  $(SRC_SERVICE) -> $(SERVICE_FILE)"
	@echo "Would install GUI:"
	@echo "  $(SRC_GUI_PY)        -> $(GUI_DIR)/gpu-power-switch-gui.py"
	@echo "  $(SRC_GUI_LAUNCHER)  -> $(GUI_BIN)"
	@echo "  $(SRC_POLICY)        -> $(POLICY_FILE)"
	@echo "  $(SRC_DESKTOP)       -> $(DESKTOP_FILE)"

test:
	@bash -n "$(SRC_SCRIPT)" && echo "script syntax OK"
	@bash -n "$(SRC_TOGGLE)" && echo "toggle syntax OK"
	@python3 -c "import xml.etree.ElementTree as ET; ET.parse('$(SRC_POLICY)')" && echo "policy XML OK"
	@python3 -c "import py_compile; py_compile.compile('$(SRC_GUI_PY)', doraise=True)" && echo "gui python OK"
