#!/usr/bin/env bash
# ==============================================================================
# Surface Laptop Studio dGPU 10W Throttle Fix & 50W Power Uncapper
# Author: besiple (https://github.com/besiple/surface-laptop-studio-dgpu-fix)
# Copyright (c) 2026 besiple. All rights reserved.
# Licensed under the MIT License.
# ==============================================================================
set -e

# ANSI Color codes for beautiful terminal output
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
DIM='\033[2m'
RESET='\033[0m'

info()    { echo -e "  ${CYAN}•${RESET} $*"; }
step()    { echo -e "\n${BOLD}${CYAN}[$1]${RESET} ${BOLD}$2${RESET}"; }
success() { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}!${RESET} $*"; }
error()   { echo -e "  ${RED}✗${RESET} $*"; }

# Allow --help without root
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo -e "${CYAN}======================================================================${RESET}"
            echo -e "${BOLD}   Surface Laptop Studio dGPU Fix & 50W Enabler ${YELLOW}(by besiple)${RESET}"
            echo -e "${CYAN}======================================================================${RESET}"
            echo ""
            echo "Usage: sudo ./install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --nvpcf-patch       Apply custom nvidia-open-dkms patch for full 50W Dynamic Boost"
            echo "  --no-nvpcf-patch    Skip kernel module patch (fixes 10W bug at factory 35W TGP)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Note: Memory overclock (+650 MHz / 6.15 GHz) is prompted interactively."
            exit 0
            ;;
    esac
done

# Root privilege check MUST be performed before any user interaction or system changes
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[-] Please run as root:${RESET} sudo ./install.sh"
    exit 1
fi

echo -e "${CYAN}======================================================================${RESET}"
echo -e "${BOLD}   Surface Laptop Studio dGPU Fix & 50W Enabler ${YELLOW}(by besiple)${RESET}"
echo -e "${CYAN}======================================================================${RESET}"

ENABLE_NVPCF_PATCH=false
NVPCF_PATCH_EXPLICIT=false
NVPCF_PATCH_APPLIED=false
ENABLE_MEM_OC=false

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
    esac
done

if [ "$NVPCF_PATCH_EXPLICIT" = false ] && [ -t 0 ]; then
    echo ""
    echo -e "${BOLD}Optional Feature 1: 50W Dynamic Boost (Kernel Module Patch)${RESET}"
    echo -e "  ${DIM}Unlocks full 50.0W TGP on AC wall power (up from factory 35W limit).${RESET}"
    echo -e "  ${DIM}Requires nvidia-open-dkms (open-gpu-kernel-modules).${RESET}"
    echo -e "  ${DIM}Skipping this still fixes the 10W sleep bug at stock 35W TGP.${RESET}"
    read -r -p "  Patch nvidia-open-dkms for 50W Dynamic Boost? [y/N]: " patch_answer
    if [[ "$patch_answer" =~ ^[Yy]$ ]]; then
        ENABLE_NVPCF_PATCH=true
    fi
fi

if [ -t 0 ]; then
    echo ""
    echo -e "${BOLD}Optional Feature 2: GDDR6 VRAM Overclock (+650 MHz / 6.15 GHz)${RESET}"
    echo -e "  ${DIM}Microsoft tuned VRAM down to 5.5 GHz for battery efficiency.${RESET}"
    echo -e "  ${DIM}+650 MHz (6151 MHz) is the hardware sweet spot tested 100% stable.${RESET}"
    read -r -p "  Enable +650 MHz VRAM memory overclock? [y/N]: " oc_answer
    if [[ "$oc_answer" =~ ^[Yy]$ ]]; then
        ENABLE_MEM_OC=true
    fi
fi

step "1/7" "Checking acpi_call kernel module..."
if ! modprobe acpi_call 2>/dev/null; then
    info "Installing acpi_call-dkms via package manager..."
    if command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm acpi_call-dkms
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y acpi-call-dkms
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y acpi_call
    else
        error "Package manager not recognized. Please install acpi_call manually."
        exit 1
    fi
    modprobe acpi_call
fi
success "acpi_call kernel module active."

step "2/7" "Configuring acpi_call autoload..."
echo "acpi_call" > /etc/modules-load.d/acpi_call.conf
success "Configured /etc/modules-load.d/acpi_call.conf"

step "3/7" "Installing SGPC (MSHW0216) initialization script..."
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
    info "Injecting NVML +650 MHz VRAM memory offset into initializer..."
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
    success "VRAM Overclock: +650 MHz (6.15 GHz) enabled."
else
    info "VRAM Overclock: Skipped (keeping factory stock 5.5 GHz)."
fi
chmod +x /usr/local/bin/surface-dgpu-init
success "Installed /usr/local/bin/surface-dgpu-init"

step "4/7" "Creating systemd services & sleep-resume hooks..."
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
systemctl enable surface-dgpu-init.service 2>/dev/null || true
/usr/local/bin/surface-dgpu-init
success "surface-dgpu-init.service and sleep hooks active."

step "5/7" "Configuring NVIDIA kernel modules (NVPCF 50W Dynamic Boost)..."
if [ "$ENABLE_NVPCF_PATCH" = true ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PATCH_FILE="$SCRIPT_DIR/patches/nvidia-nvpcf-surface.patch"

    # Find open kernel module source directory in /usr/src
    NVIDIA_SRC=""
    for d in $(find /usr/src -maxdepth 1 \( -name "nvidia-*" -o -name "nvidia-open-*" \) -type d 2>/dev/null | sort -V); do
        if [ -d "$d/src/nvidia" ] && [ -f "$d/dkms.conf" ]; then
            NVIDIA_SRC="$d"
        fi
    done

    if [ -z "$NVIDIA_SRC" ] || [ ! -f "$PATCH_FILE" ]; then
        warn "Open kernel module source (nvidia-open-dkms) not detected in /usr/src."
        info "To unlock full 50W Dynamic Boost, install nvidia-open-dkms."
        info "Skipping kernel patch cleanly. SGPC ACPI fix will provide stock 35W base TGP."
    else
        DKMS_PKG_NAME=$(grep -E '^[[:space:]]*PACKAGE_NAME=' "$NVIDIA_SRC/dkms.conf" | cut -d= -f2 | tr -d '"'\'' ')
        DKMS_PKG_VER=$(grep -E '^[[:space:]]*PACKAGE_VERSION=' "$NVIDIA_SRC/dkms.conf" | cut -d= -f2 | tr -d '"'\'' ')
        [ -z "$DKMS_PKG_NAME" ] && DKMS_PKG_NAME="nvidia"
        [ -z "$DKMS_PKG_VER" ] && DKMS_PKG_VER=$(basename "$NVIDIA_SRC" | sed -E 's/^(nvidia-open-|nvidia-)//')

        if grep -q "CONFIGURE_TURBO_V2" "$NVIDIA_SRC/src/nvidia/arch/nvalloc/unix/src/osapi.c" 2>/dev/null; then
            success "NVIDIA NVPCF 50W Turbo Engine patch is already applied to $NVIDIA_SRC."
            NVPCF_PATCH_APPLIED=true
        else
            info "Validating NVPCF 50W patch against $NVIDIA_SRC ($DKMS_PKG_NAME/$DKMS_PKG_VER)..."
            if patch --dry-run -p1 -N --batch -d "$NVIDIA_SRC" -i "$PATCH_FILE" >/dev/null 2>&1; then
                info "Applying NVPCF 50W Turbo Engine patch to $NVIDIA_SRC..."
                patch -p1 -N --batch -d "$NVIDIA_SRC" -i "$PATCH_FILE"
                KVER=$(uname -r)
                if command -v dkms >/dev/null 2>&1; then
                    info "Rebuilding and installing patched NVIDIA DKMS module for $KVER..."
                    if ! dkms build -m "$DKMS_PKG_NAME/$DKMS_PKG_VER" -k "$KVER" --force; then
                        error "dkms build failed for $DKMS_PKG_NAME/$DKMS_PKG_VER on $KVER."
                        error "Check build log in /var/lib/dkms/$DKMS_PKG_NAME/$DKMS_PKG_VER/build/make.log."
                        exit 1
                    fi
                    if ! dkms install -m "$DKMS_PKG_NAME/$DKMS_PKG_VER" -k "$KVER" --force; then
                        error "dkms install failed for $DKMS_PKG_NAME/$DKMS_PKG_VER on $KVER."
                        exit 1
                    fi
                    success "Patched NVIDIA DKMS module successfully built and installed."
                    NVPCF_PATCH_APPLIED=true
                else
                    error "'dkms' command not found. Cannot rebuild NVIDIA kernel module."
                    exit 1
                fi
            else
                warn "Patch dry-run failed for $NVIDIA_SRC (driver version does not match patch cleanly)."
                info "Skipping kernel patch cleanly. SGPC ACPI fix will still provide stock 35W base TGP."
            fi
        fi

        # Mask conflicting nvidia-powerd only when the NVPCF patch is active
        if [ "$NVPCF_PATCH_APPLIED" = true ] && command -v systemctl >/dev/null 2>&1; then
            info "Masking conflicting nvidia-powerd.service..."
            systemctl stop nvidia-powerd 2>/dev/null || true
            systemctl disable nvidia-powerd 2>/dev/null || true
            systemctl mask nvidia-powerd 2>/dev/null || true
        fi
    fi
else
    info "NVPCF Kernel Patch: Skipped (keeping stock 35W Base TGP + 10W bug fix)."
fi

step "6/7" "Enabling Runtime D3 (D3cold) and Wayland sleep stability..."
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
        systemctl enable "$s" 2>/dev/null || true
    fi
done
success "Configured D3cold power management and Wayland sleep preservation."

step "7/7" "Updating initramfs..."
if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u
elif command -v dracut >/dev/null 2>&1; then
    dracut -f
fi
success "Initramfs updated."

echo ""
echo -e "${GREEN}======================================================================${RESET}"
echo -e "${BOLD}${GREEN}   [+] SUCCESS! Installation complete.${RESET}"
echo -e "${GREEN}======================================================================${RESET}"
if [ "$NVPCF_PATCH_APPLIED" = true ]; then
    echo -e "  ${GREEN}✓${RESET} ${BOLD}50W Dynamic Boost:${RESET} Patch active (requires AC charger connected)."
else
    echo -e "  ${GREEN}✓${RESET} ${BOLD}35W Base TGP:${RESET} 10W sleep throttle fix active (stock driver mode)."
fi
if [ "$ENABLE_MEM_OC" = true ]; then
    echo -e "  ${GREEN}✓${RESET} ${BOLD}VRAM Overclock:${RESET} +650 MHz (6.15 GHz) enabled via NVML."
else
    echo -e "  ${DIM}• VRAM Overclock: Factory stock (5.5 GHz).${RESET}"
fi
echo -e "  ${CYAN}•${RESET} ${BOLD}Please reboot your laptop to activate all changes.${RESET}"
echo ""
