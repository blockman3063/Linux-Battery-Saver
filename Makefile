# gpu-power-switch — top-level Makefile
#
# Thin wrapper around install.sh / uninstall.sh. The shell scripts are
# the source of truth — this Makefile exists for people who expect
# `make install` to work on a project.
#
# Targets:
#   make install    — run install.sh (requires sudo)
#   make uninstall  — run uninstall.sh (requires sudo)
#   make test       — run all syntax/validation tests
#   make dry-run    — show what install would copy (no root needed)

PREFIX       ?= /usr
ETCDIR       ?= /etc

.PHONY: install uninstall test dry-run help

help:
	@echo "Targets:"
	@echo "  make install    Install everything (CLI, GUI, polkit, udev, systemd, modprobe)"
	@echo "  make uninstall  Remove all installed files"
	@echo "  make test       Run syntax / XML / python validation"
	@echo "  make dry-run    List what install would do"

install:
	@PREFIX='$(PREFIX)' ETCDIR='$(ETCDIR)' ./install.sh

uninstall:
	@PREFIX='$(PREFIX)' ETCDIR='$(ETCDIR)' ./uninstall.sh

test:
	@bash -n usr-lib/gpu-power-switch.sh           && echo "script syntax OK"
	@bash -n usr-lib/gpu-power-switch-toggle       && echo "toggle syntax OK"
	@bash -n usr-lib/gpu-power-switch-manual       && echo "manual syntax OK"
	@bash -n usr-lib/gpu-power-switch-mode         && echo "mode syntax OK"
	@bash -n install.sh                            && echo "install.sh syntax OK"
	@bash -n uninstall.sh                          && echo "uninstall.sh syntax OK"
	@python3 -c "import xml.etree.ElementTree as ET; ET.parse('polkit/org.linuxbatterysaver.policy')" && echo "policy XML OK"
	@python3 -c "import py_compile; py_compile.compile('gui/gpu-power-switch-gui.py', doraise=True)" && echo "gui python OK"
	@desktop-file-validate desktop/linux-battery-saver.desktop && echo "desktop file OK"

dry-run:
	@echo "Would install CLI:"
	@echo "  usr-lib/gpu-power-switch.sh         -> $(PREFIX)/lib/gpu-power-switch/"
	@echo "  usr-lib/gpu-power-switch-toggle     -> $(PREFIX)/lib/gpu-power-switch/"
	@echo "  usr-lib/gpu-power-switch-manual     -> $(PREFIX)/lib/gpu-power-switch/"
	@echo "  systemd/gpu-power-switch.service    -> $(ETCDIR)/systemd/system/"
	@echo "  udev/99-gpu-power-switch.rules      -> $(ETCDIR)/udev/rules.d/"
	@echo "Would install GUI:"
	@echo "  gui/gpu-power-switch-gui.py         -> $(PREFIX)/lib/gpu-power-switch/gui/"
	@echo "  usr-bin/gpu-power-switch-gui        -> $(PREFIX)/bin/"
	@echo "  polkit/org.linuxbatterysaver.policy -> $(PREFIX)/share/polkit-1/actions/"
	@echo "  desktop/linux-battery-saver.desktop -> $(PREFIX)/share/applications/"
	@echo "Would install modprobe config:"
	@echo "  modprobe.d/nvidia-runtimepm.conf    -> /lib/modprobe.d/"
