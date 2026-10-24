#!/usr/bin/env bash
set -e

echo "=== Uninstalling Surface Laptop Studio dGPU Fix ==="

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root (e.g. sudo ./uninstall.sh)"
  exit 1
fi

systemctl disable --now surface-dgpu-init.service 2>/dev/null || true
rm -f /etc/systemd/system/surface-dgpu-init.service
rm -f /usr/local/bin/surface-dgpu-init
rm -f /usr/lib/systemd/system-sleep/surface-dgpu-init.sh
rm -f /etc/udev/rules.d/80-nvidia-pm.rules

cat << "EOF" > /etc/modprobe.d/nvidia-runtimepm.conf
# Fix for Surface Laptop Studio 10W power limit / dynamic boost throttle bug
options nvidia NVreg_DynamicPowerManagement=0x00 NVreg_PreserveVideoMemoryAllocations=1
options nvidia-drm modeset=1
EOF

systemctl daemon-reload
udevadm control --reload-rules

if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u
elif command -v dracut >/dev/null 2>&1; then
    dracut -f
fi

echo "[+] Uninstalled. Reverted to static 35W (D3cold disabled)."
