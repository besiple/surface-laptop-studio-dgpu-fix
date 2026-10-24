#!/usr/bin/env bash
set -e

echo "=== Surface Laptop Studio dGPU 10W Bug Fix & D3cold Enabler ==="

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root (e.g. sudo ./install.sh)"
  exit 1
fi

echo "[1/6] Checking acpi_call module..."
if ! modprobe acpi_call 2>/dev/null; then
    echo "      Installing acpi_call-dkms..."
    if command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm acpi_call-dkms
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y acpi-call-dkms
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y acpi_call
    else
        echo "[-] Package manager not recognized. Please install acpi_call manually."
        exit 1
    fi
    modprobe acpi_call
fi

echo "[2/6] Configuring acpi_call autoload..."
echo "acpi_call" > /etc/modules-load.d/acpi_call.conf

echo "[3/6] Installing SGPC (MSHW0216) initialization script..."
cat << "EOF" > /usr/local/bin/surface-dgpu-init
#!/bin/bash
# Initialize Surface Graphics Power Controller (MSHW0216 / SGPC)
# Fixes the Surface Laptop Studio 10W power limit throttle bug upon D3cold wake-up
modprobe acpi_call 2>/dev/null
if [ -e /proc/acpi/call ]; then
    # Function 7 with Arg3=1 sets SACT=1, clears negative power offsets (PWRA=0, PWRD=0), and sends unthrottle notification 0xD1
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 7 1' > /proc/acpi/call
    # Function 1 with Arg3=1 enables SMF Boost
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 1 1' > /proc/acpi/call
fi
EOF
chmod +x /usr/local/bin/surface-dgpu-init

echo "[4/6] Creating systemd service & resume hook..."
cat << "EOF" > /etc/systemd/system/surface-dgpu-init.service
[Unit]
Description=Initialize Surface Graphics Power Controller (Fix 10W Bug)
DefaultDependencies=no
After=systemd-modules-load.service
Before=display-manager.service graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/surface-dgpu-init
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF

mkdir -p /usr/lib/systemd/system-sleep/
cat << "EOF" > /usr/lib/systemd/system-sleep/surface-dgpu-init.sh
#!/bin/bash
if [ "$1" = "post" ]; then
    /usr/local/bin/surface-dgpu-init
fi
EOF
chmod +x /usr/lib/systemd/system-sleep/surface-dgpu-init.sh

systemctl daemon-reload
systemctl enable surface-dgpu-init.service
/usr/local/bin/surface-dgpu-init

echo "[5/6] Enabling Runtime D3 (D3cold / 0W idle) in modprobe and udev..."
cat << "EOF" > /etc/modprobe.d/nvidia-runtimepm.conf
# Dynamic Power Management (RTD3) with SGPC Fix
options nvidia NVreg_DynamicPowerManagement=0x02 NVreg_PreserveVideoMemoryAllocations=1
options nvidia-drm modeset=1
EOF

cat << "EOF" > /etc/udev/rules.d/80-nvidia-pm.rules
# Enable runtime PM for NVIDIA VGA/3D controller devices on add/bind
ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03*", TEST=="power/control", ATTR{power/control}="auto"
EOF

udevadm control --reload-rules
udevadm trigger

echo "[6/6] Updating initramfs..."
if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u
elif command -v dracut >/dev/null 2>&1; then
    dracut -f
fi

echo ""
echo "[+] SUCCESS! Fix installed."
echo "    Please reboot your laptop to activate D3cold power management."
