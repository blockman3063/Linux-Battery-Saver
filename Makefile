# gpu-power-switch — Makefile
#
# Targets:
#   make install   — install udev rule, script, systemd unit; reload udev; enable service
#   make uninstall — remove installed files; disable service; reload udev
#   make dry-run   — show what install would do, without touching the system
#
# Install paths follow the Debian/Ubuntu conventions:
#   /etc/udev/rules.d/99-gpu-power-switch.rules
#   /usr/lib/gpu-power-switch/gpu-power-switch.sh
#   /etc/systemd/system/gpu-power-switch.service

PREFIX       ?= /usr
ETCDIR       ?= /etc
UDEV_RULESDIR = $(ETCDIR)/udev/rules.d
LIBDIR       = $(PREFIX)/lib/gpu-power-switch
SYSTEMD_DIR  = $(ETCDIR)/systemd/system

UDEV_FILE    = $(UDEV_RULESDIR)/99-gpu-power-switch.rules
SCRIPT_FILE  = $(LIBDIR)/gpu-power-switch.sh
SERVICE_FILE = $(SYSTEMD_DIR)/gpu-power-switch.service

SRC_UDEV     = udev/99-gpu-power-switch.rules
SRC_SCRIPT   = usr-lib/gpu-power-switch.sh
SRC_SERVICE  = systemd/gpu-power-switch.service

.PHONY: install uninstall dry-run reload-udev enable-service disable-service

install:
	@echo ">>> Installing to $(PREFIX)/, $(ETCDIR)/"
	install -d -m 755 "$(LIBDIR)"
	install -d -m 755 "$(UDEV_RULESDIR)"
	install -d -m 755 "$(SYSTEMD_DIR)"
	install -m 644 "$(SRC_UDEV)"    "$(UDEV_FILE)"
	install -m 755 "$(SRC_SCRIPT)"  "$(SCRIPT_FILE)"
	install -m 644 "$(SRC_SERVICE)" "$(SERVICE_FILE)"
	@echo ">>> Reloading udev rules"
	udevadm control --reload-rules
	udevadm trigger --subsystem-match=power_supply
	@echo ">>> Enabling systemd unit (use 'make disable-service' to opt out)"
	-systemctl daemon-reload
	-systemctl enable gpu-power-switch.service
	-systemctl start  gpu-power-switch.service
	@echo "Done. Plug/unplug AC to test."

uninstall:
	@echo ">>> Disabling + removing gpu-power-switch.service"
	-systemctl disable --now gpu-power-switch.service
	rm -f "$(SERVICE_FILE)"
	-systemctl daemon-reload
	@echo ">>> Removing script + udev rule"
	rm -f "$(SCRIPT_FILE)"
	rmdir "$(LIBDIR)" 2>/dev/null || true
	rm -f "$(UDEV_FILE)"
	udevadm control --reload-rules
	@echo "Done."

dry-run:
	@echo "Would install:"
	@echo "  $(SRC_UDEV)    -> $(UDEV_FILE)"
	@echo "  $(SRC_SCRIPT)  -> $(SCRIPT_FILE)"
	@echo "  $(SRC_SERVICE) -> $(SERVICE_FILE)"