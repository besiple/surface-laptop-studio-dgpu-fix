#!/usr/bin/env bash
# ==============================================================================
# Surface Laptop Studio dGPU Fix Uninstaller
# Author: besiple (https://github.com/besiple/surface-laptop-studio-dgpu-fix)
# Copyright (c) 2026 besiple. All rights reserved.
# Licensed under the MIT License.
# ==============================================================================
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root (e.g. sudo ./uninstall.sh)"
  exit 1
fi

echo "=== Surface Laptop Studio dGPU Fix Uninstaller (by besiple) ==="

echo "[1/6] Stopping and disabling systemd services..."
systemctl stop surface-dgpu-init.service 2>/dev/null || true
systemctl disable surface-dgpu-init.service 2>/dev/null || true
systemctl stop surface-dgpu-power.service 2>/dev/null || true
systemctl disable surface-dgpu-power.service 2>/dev/null || true

for s in nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service; do
    if systemctl is-enabled "$s" >/dev/null 2>&1; then
        echo "      Disabling $s..."
        systemctl disable "$s" 2>/dev/null || true
    fi
done

if command -v systemctl >/dev/null 2>&1; then
    echo "      Unmasking nvidia-powerd.service..."
    systemctl unmask nvidia-powerd 2>/dev/null || true
fi

echo "[2/6] Resetting VRAM memory clocks to factory default (0 MHz offset)..."
python3 -c "
import ctypes
try:
    nvml = ctypes.CDLL('libnvidia-ml.so.1')
    nvml.nvmlInit()
    h = ctypes.c_void_p()
    if nvml.nvmlDeviceGetHandleByIndex(0, ctypes.byref(h)) == 0:
        nvml.nvmlDeviceSetMemClkVfOffset(h, 0)
    nvml.nvmlShutdown()
except Exception:
    pass
" 2>/dev/null || true

echo "[3/6] Removing installed scripts and services..."
rm -f /usr/local/bin/surface-dgpu-init
rm -f /usr/local/bin/surface-dgpu-50w.sh
rm -f /etc/systemd/system/surface-dgpu-init.service
rm -f /etc/systemd/system/surface-dgpu-power.service
rm -f /usr/lib/systemd/system-sleep/surface-dgpu-init.sh
systemctl daemon-reload

echo "[4/6] Removing runtime PM and modprobe overrides..."
rm -f /etc/modprobe.d/nvidia-runtimepm.conf
rm -f /etc/udev/rules.d/80-nvidia-pm.rules
rm -f /etc/modules-load.d/acpi_call.conf
udevadm control --reload-rules || true

echo "[5/6] Resetting dGPU power limit to default (35W)..."
if [ -e /proc/acpi/call ]; then
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 3 0' > /proc/acpi/call || true
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 2 0' > /proc/acpi/call || true
fi

echo "[6/6] Updating initramfs..."
if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u
elif command -v dracut >/dev/null 2>&1; then
    dracut -f
fi

echo ""
echo "[+] Successfully uninstalled."
echo "    Note: If you previously opted into the custom NVPCF 50W kernel module patch,"
echo "    reinstall stock nvidia-open-dkms to revert to vendor kernel modules:"
echo "      Arch Linux:    sudo pacman -S --rebuild nvidia-open-dkms"
echo "      Fedora:        sudo dnf reinstall akmod-nvidia-open"
echo "      Ubuntu/Debian: sudo apt install --reinstall nvidia-kernel-source-open"
