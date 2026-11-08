#!/usr/bin/env bash
set -e

echo "=== Surface Laptop Studio dGPU Fix Uninstaller ==="

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root (e.g. sudo ./uninstall.sh)"
  exit 1
fi

echo "[1/4] Stopping and disabling systemd services..."
systemctl stop surface-dgpu-init.service 2>/dev/null || true
systemctl disable surface-dgpu-init.service 2>/dev/null || true
systemctl stop surface-dgpu-power.service 2>/dev/null || true
systemctl disable surface-dgpu-power.service 2>/dev/null || true

echo "[2/4] Removing installed scripts and services..."
rm -f /usr/local/bin/surface-dgpu-init
rm -f /usr/local/bin/surface-dgpu-50w.sh
rm -f /etc/systemd/system/surface-dgpu-init.service
rm -f /etc/systemd/system/surface-dgpu-power.service
rm -f /usr/lib/systemd/system-sleep/surface-dgpu-init.sh
systemctl daemon-reload

echo "[3/4] Removing runtime PM and modprobe overrides..."
rm -f /etc/modprobe.d/nvidia-runtimepm.conf
rm -f /etc/udev/rules.d/80-nvidia-pm.rules
rm -f /etc/modules-load.d/acpi_call.conf
udevadm control --reload-rules || true

echo "[4/4] Resetting dGPU power limit to default (35W)..."
if [ -e /proc/acpi/call ]; then
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 3 0' > /proc/acpi/call || true
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 2 0' > /proc/acpi/call || true
fi

echo "[+] Successfully uninstalled."
