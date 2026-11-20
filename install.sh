#!/usr/bin/env bash
# ==============================================================================
# Surface Laptop Studio dGPU 10W Throttle Fix & 50W Power Uncapper
# Author: besiple (https://github.com/besiple/surface-laptop-studio-dgpu-fix)
# Copyright (c) 2026 besiple. All rights reserved.
# Licensed under the MIT License.
# ==============================================================================
set -e

# Allow --help without root
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "Usage: sudo ./install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --nvpcf-patch       Apply custom nvidia-open-dkms patch for full 50W Dynamic Boost"
            echo "  --no-nvpcf-patch    Skip kernel module patch (fixes 10W bug at factory 35W TGP)"
            echo "  --mem-oc            Enable +650 MHz VRAM memory overclock sweet spot (6.15 GHz)"
            echo "  --no-oc             Keep factory stock memory clocks (5.5 GHz)"
            echo "  -h, --help          Show this help message"
            exit 0
            ;;
    esac
done

# Root privilege check MUST be performed before any user interaction or system changes
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root (e.g. sudo ./install.sh)"
  exit 1
fi

echo "=== Surface Laptop Studio dGPU 10W Bug Fix & 50W Enabler (by besiple) ==="

ENABLE_NVPCF_PATCH=false
NVPCF_PATCH_EXPLICIT=false
ENABLE_MEM_OC=false
MEM_OC_EXPLICIT=false

for arg in "$@"; do
    case "$arg" in
        --nvpcf-patch|--patch)
            ENABLE_NVPCF_PATCH=true
            NVPCF_PATCH_EXPLICIT=true
            ;;
        --no-nvpcf-patch|--no-patch)
            ENABLE_NVPCF_PATCH=false
            NVPCF_PATCH_EXPLICIT=true
            ;;
        --mem-oc|--oc)
            ENABLE_MEM_OC=true
            MEM_OC_EXPLICIT=true
            ;;
        --no-oc|--no-mem-oc)
            ENABLE_MEM_OC=false
            MEM_OC_EXPLICIT=true
            ;;
    esac
done

if [ "$NVPCF_PATCH_EXPLICIT" = false ] && [ -t 0 ]; then
    echo ""
    echo "Optional: Patch nvidia-open-dkms kernel modules with NVPCF Turbo Engine."
    echo "This unlocks full 50.0W Dynamic Boost when connected to AC wall power."
    echo "Skipping this still permanently fixes the 10W sleep throttle bug and provides"
    echo "the factory stock 35.0W Base TGP without modifying vendor kernel modules."
    read -r -p "Would you like to patch nvidia-open-dkms for 50W Dynamic Boost? [y/N]: " patch_answer
    if [[ "$patch_answer" =~ ^[Yy]$ ]]; then
        ENABLE_NVPCF_PATCH=true
    fi
fi

if [ "$MEM_OC_EXPLICIT" = false ] && [ -t 0 ]; then
    echo ""
    echo "Optional: Microsoft tuned the GDDR6 VRAM down to 5.5 GHz for battery efficiency."
    read -r -p "Would you like to enable the +650 MHz VRAM memory overclock sweet spot (6.15 GHz)? [y/N]: " oc_answer
    if [[ "$oc_answer" =~ ^[Yy]$ ]]; then
        ENABLE_MEM_OC=true
    fi
fi

echo ""
echo "[1/7] Checking acpi_call module..."
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

echo "[2/7] Configuring acpi_call autoload..."
echo "acpi_call" > /etc/modules-load.d/acpi_call.conf

echo "[3/7] Installing SGPC (MSHW0216) initialization script..."
cat << "EOF" > /usr/local/bin/surface-dgpu-init
#!/bin/bash
# ==============================================================================
# Surface Graphics Power Controller (MSHW0216 / SGPC) Initializer
# Author: besiple (https://github.com/besiple/surface-laptop-studio-dgpu-fix)
# Copyright (c) 2026 besiple. All rights reserved.
# Licensed under the MIT License.
# ==============================================================================

# Ensure NVIDIA driver client is alive before firing ACPI notification
nvidia-smi -q >/dev/null 2>&1 || true

modprobe acpi_call 2>/dev/null
if [ -e /proc/acpi/call ]; then
    # Function 7 with Arg3=1 sets SACT=1, clears negative power offsets, and sends unthrottle notification 0xD1
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 7 1' > /proc/acpi/call
    # Function 3 with Arg3=0x78 sets AC cTGP power offset to +15W (120 * 125mW = +15000mW = +15W cTGP boost)
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 3 0x78' > /proc/acpi/call
    # Function 2 with Arg3=0x0320 sets SPWR to 50W (800 * 0.0625W = 50.0W) and notifies NPCF (0xC0)
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 2 0x0320' > /proc/acpi/call
    # Function 1 with Arg3=1 enables SMF Boost
    echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 1 1' > /proc/acpi/call
fi
EOF

if [ "$ENABLE_MEM_OC" = true ]; then
    echo "      Applying optional +650 MHz VRAM memory overclock..."
    cat << "EOF" >> /usr/local/bin/surface-dgpu-init

# Apply VRAM Memory Clock Offset (+650 MHz / 1300 MT/s effective sweet spot) via NVML
python3 -c "
import ctypes
try:
    nvml = ctypes.CDLL('libnvidia-ml.so.1')
    nvml.nvmlInit()
    h = ctypes.c_void_p()
    if nvml.nvmlDeviceGetHandleByIndex(0, ctypes.byref(h)) == 0:
        nvml.nvmlDeviceSetMemClkVfOffset(h, 1300)
    nvml.nvmlShutdown()
except Exception:
    pass
" 2>/dev/null || true
EOF
else
    echo "      VRAM Overclock: Skipped (keeping factory stock 5.5 GHz)"
fi
chmod +x /usr/local/bin/surface-dgpu-init

echo "[4/7] Creating systemd service & resume hook..."
systemctl enable --now nvidia-persistenced.service 2>/dev/null || true

cat << "EOF" > /etc/systemd/system/surface-dgpu-init.service
[Unit]
Description=Initialize Surface Graphics Power Controller (Fix 10W Bug & Unlock 50W TGP)
After=systemd-modules-load.service nvidia-persistenced.service
Wants=nvidia-persistenced.service
Before=display-manager.service graphical.target
Conflicts=nvidia-powerd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/surface-dgpu-init
RemainAfterExit=yes

[Install]
WantedBy=graphical.target multi-user.target
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

echo "[5/7] Configuring NVIDIA kernel modules (NVPCF 50W Dynamic Boost)..."
if [ "$ENABLE_NVPCF_PATCH" = true ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PATCH_FILE="$SCRIPT_DIR/patches/nvidia-nvpcf-surface.patch"

    # Find open kernel module source directory in /usr/src (supporting nvidia-* and nvidia-open-*)
    NVIDIA_SRC=""
    for d in $(find /usr/src -maxdepth 1 \( -name "nvidia-*" -o -name "nvidia-open-*" \) -type d 2>/dev/null | sort -V); do
        if [ -d "$d/src/nvidia" ] && [ -f "$d/dkms.conf" ]; then
            NVIDIA_SRC="$d"
        fi
    done

    if [ -z "$NVIDIA_SRC" ] || [ ! -f "$PATCH_FILE" ]; then
        echo "[!] Note: Open kernel module source (nvidia-open-dkms) not detected in /usr/src."
        echo "    To unlock full 50W hardware Dynamic Boost, please install nvidia-open-dkms."
        echo "    Skipping NVPCF patch. SGPC ACPI fix will still provide stock 35W base TGP."
    else
        DKMS_PKG_NAME=$(grep -E '^[[:space:]]*PACKAGE_NAME=' "$NVIDIA_SRC/dkms.conf" | cut -d= -f2 | tr -d '"'\'' ')
        DKMS_PKG_VER=$(grep -E '^[[:space:]]*PACKAGE_VERSION=' "$NVIDIA_SRC/dkms.conf" | cut -d= -f2 | tr -d '"'\'' ')
        [ -z "$DKMS_PKG_NAME" ] && DKMS_PKG_NAME="nvidia"
        [ -z "$DKMS_PKG_VER" ] && DKMS_PKG_VER=$(basename "$NVIDIA_SRC" | sed -E 's/^(nvidia-open-|nvidia-)//')

        if grep -q "CONFIGURE_TURBO_V2" "$NVIDIA_SRC/src/nvidia/arch/nvalloc/unix/src/osapi.c" 2>/dev/null; then
            echo "      NVIDIA NVPCF 50W Turbo Engine patch is already applied to $NVIDIA_SRC."
        else
            echo "      Validating NVPCF 50W patch against $NVIDIA_SRC ($DKMS_PKG_NAME/$DKMS_PKG_VER)..."
            if patch --dry-run -p1 -N --batch -d "$NVIDIA_SRC" -i "$PATCH_FILE" >/dev/null 2>&1; then
                echo "      Applying NVPCF 50W Turbo Engine patch to $NVIDIA_SRC..."
                patch -p1 -N --batch -d "$NVIDIA_SRC" -i "$PATCH_FILE"
                KVER=$(uname -r)
                if command -v dkms >/dev/null 2>&1; then
                    echo "      Rebuilding and installing patched NVIDIA DKMS module for $KVER..."
                    if ! dkms build -m "$DKMS_PKG_NAME/$DKMS_PKG_VER" -k "$KVER" --force; then
                        echo "[-] Error: dkms build failed for $DKMS_PKG_NAME/$DKMS_PKG_VER on $KVER."
                        echo "    Check build log in /var/lib/dkms/$DKMS_PKG_NAME/$DKMS_PKG_VER/build/make.log."
                        exit 1
                    fi
                    if ! dkms install -m "$DKMS_PKG_NAME/$DKMS_PKG_VER" -k "$KVER" --force; then
                        echo "[-] Error: dkms install failed for $DKMS_PKG_NAME/$DKMS_PKG_VER on $KVER."
                        exit 1
                    fi
                    echo "      Patched NVIDIA DKMS module successfully built and installed."
                else
                    echo "[-] Error: 'dkms' command not found. Cannot rebuild NVIDIA kernel module."
                    exit 1
                fi
            else
                echo "[!] Warning: Patch dry-run failed for $NVIDIA_SRC."
                echo "    The driver source version ($DKMS_PKG_VER) does not match the patch cleanly."
                echo "    Skipping NVPCF patch cleanly. SGPC ACPI fix will still provide stock 35W base TGP."
            fi
        fi

        # Mask incompatible nvidia-powerd (conflicts with Surface ACPI MSHW0216 power steering and forces 35W lock)
        if command -v systemctl >/dev/null 2>&1; then
            echo "      Masking conflicting nvidia-powerd.service..."
            systemctl stop nvidia-powerd 2>/dev/null || true
            systemctl disable nvidia-powerd 2>/dev/null || true
            systemctl mask nvidia-powerd 2>/dev/null || true
        fi
    fi
else
    echo "      NVPCF Kernel Patch: Skipped (keeping stock 35W Base TGP + 10W bug fix)"
fi

echo "[6/7] Enabling Runtime D3 (D3cold) and Wayland sleep stability..."
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

# Enable systemd sleep services required for NVreg_PreserveVideoMemoryAllocations=1
for s in nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service; do
    if systemctl list-unit-files "$s" >/dev/null 2>&1; then
        echo "      Enabling $s for VRAM preservation across sleep..."
        systemctl enable "$s" 2>/dev/null || true
    fi
done

echo "[7/7] Updating initramfs..."
if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u
elif command -v dracut >/dev/null 2>&1; then
    dracut -f
fi

echo ""
echo "[+] SUCCESS! Fix installed."
if [ "$ENABLE_NVPCF_PATCH" = true ]; then
    echo "    1. 50W Dynamic Boost: Patch applied (requires AC charger connected)."
else
    echo "    1. 35W Base TGP: 10W sleep throttle fix active (unpatched stock driver mode)."
fi
if [ "$ENABLE_MEM_OC" = true ]; then
    echo "    2. VRAM Overclock: +650 MHz (6.15 GHz) enabled via NVML."
else
    echo "    2. VRAM Overclock: Factory stock (5.5 GHz)."
fi
echo "    3. Please reboot your laptop to load kernel configurations and activate D3cold."
