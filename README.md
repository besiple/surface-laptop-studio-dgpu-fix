# Surface Laptop Studio dGPU 10W Bug Fix, D3cold Enabler & Dynamic Boost

A complete solution for Microsoft Surface Laptop Studio (and SLS 2) running Linux to:
1. Fix the discrete GPU waking up throttled to **10W / P8 state** upon resuming from sleep.
2. Enable true **D3cold deep sleep** (`0W / 0 MHz` in idle, saving laptop battery).
3. Enable official **NVIDIA Dynamic Boost** (up to **50W Max TGP**) via a DKMS patch for `nvidia-powerd`.
4. Maximize performance with a **+650 MHz (6.15 GHz)** memory overclock sweet spot.

---

## 1. The 10W Throttle Bug & Root Cause (ACPI Reverse Engineering)

### The Problem
On the Surface Laptop Studio under Linux, enabling NVIDIA Runtime D3 (RTD3 / D3cold) causes the discrete GPU (RTX 3050 Ti Mobile) to wake up throttled down to a hard **10W power limit (P8 state)**, resulting in unplayable ~10–15 FPS in games and 3D workloads.

Historically, the Linux-Surface community recommended disabling runtime power management completely (`NVreg_DynamicPowerManagement=0x00`), which kept the GPU awake 24/7 at ~3.5W–10W and caused significant battery drain and heat.

### Root Cause
By disassembling the ACPI tables (`DSDT` and `SSDT7`), we discovered:
1. In `SSDT7`, the dGPU power resource `PRPD._ON` executes upon wake-up:
   ```asl
   PowerResource (PRPD, 0x00, 0x0000)
   {
       Method (_ON, 0, Serialized)
       {
           ...
           If ((ToInteger (\_SB.SGPC.SACT) == One))
           {
               Notify (\_SB.SGPC, 0x81) // Normal power-on notification
           }
           Else
           {
               Notify (\_SB.PC00.RP09.PXSX, 0xD5) // EMERGENCY THROTTLE TO 10W!
           }
       }
   }
   ```
2. Device `\_SB.SGPC` (ACPI Hardware ID: **`MSHW0216`**) is the **Microsoft Surface Graphics Power Controller**.
3. At boot, `SACT` is `0`, and negative power offsets (`PWRA = 0xFF88`, `PWRD = 0xFFB0`) are applied to the NVIDIA driver via `NPCF`.
4. On Windows, Microsoft's proprietary `SurfaceDgpuPwr.sys` driver initializes `MSHW0216` by calling its `_DSM` (UUID: `a99df1bb-b888-42b7-9ced-12810bfe9d90`, Function `0x07`, `Arg3 = 1`), setting `SACT = 1`, clearing offsets, and issuing unthrottle event `0xD1`.
5. On Linux, **no kernel driver existed for `MSHW0216`**. Because `SACT` was left at `0`, every time the GPU woke from D3cold, ACPI fired notification `0xD5`, locking the card to 10W.

### The Fix
Using `acpi_call`, we initialize `MSHW0216` at boot time and on system resume:
1. `_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 7 1` (sets `SACT = 1`, clears offsets, emits unthrottle `0xD1`)
2. `_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 1 1` (enables SMF boost state)

The GPU now wakes at its full sustained **35W Base TGP** (P0 state, ~750+ FPS in `glmark2`).

---

## 2. Dynamic Boost (35W Base -> 50W Max) & `nvidia-powerd`

The mobile RTX 3050 Ti has an official spec of **35W Base TGP + 15W Dynamic Boost = 50W Max TGP**.

### Why `nvidia-powerd` Failed on Surface Linux
When `nvidia-powerd` starts, it attempts to initialize the NVPCF (NVIDIA Platform Control Framework) interface by calling ACPI `\_SB.NPCF._DSM`:
1. **Function 0 Masking:** In Microsoft's SSDT7, Function 0 returned `0xC7` instead of `0xFF`, hiding Functions 3 & 4 (the static AC/DC power limits tables).
2. **Missing Function 8:** `nvidia-powerd` queries Function 8 (`NVPCF0100_CTRL_CONFIG_DSM_2X_FUNC_GET_DC_SYSTEM_POWER_LIMITS_TABLE`) to get battery state-of-charge limits. Microsoft did not implement Function 8 in ACPI (handling battery power capping directly inside the SAM EC chip instead). As a result, `nvidia-powerd` failed with:
   ```text
   ERROR! DC power limits table is not supported
   ERROR! Failed to get SysPwrLimitGetInfo!!
   ```

### The DKMS Patch
We created a clean kernel-driver patch (`patches/nvidia-nvpcf-surface.patch`) for `nvidia-open-dkms`:
* Unmasks Function 0 to report all supported tables (`0xFF` and bit 8).
* Synthesizes the missing 21-byte Function 8 table (`0x10` version, 100% threshold, 35W max CPU, 10A battery limit).

With this patch, `nvidia-powerd` starts cleanly, monitors CPU MSR energy counters (`MSR_PKG_ENERGY_STATUS`), and dynamically balances thermal headroom up to **50W Max Power Limit**:
```text
$ nvidia-smi -q -d POWER
    GPU Ceiling Power Limit
        Current Power Limit : 35.00 W
        Default Power Limit : 35.00 W
    Min Power Limit         : 1.00 W
    Max Power Limit         : 50.00 W
```

> **Note:** In GUI monitoring tools (like Mission Center), the static baseline will display as **35.0 W** during idle/moderate load because 35W is the base ceiling. When heavy 3D GPU load occurs while CPU load is low, Dynamic Boost dynamically draws from the +15W boost budget up to 50W.

---

## 3. Memory Overclocking (+650 MHz / 6.15 GHz Sweet Spot)

The GA107M mobile memory runs at 5501 MHz default. Testing demonstrated:
* Default: 5501 MHz (~740 FPS)
* +500 MHz: 6001 MHz (~775 FPS)
* **+650 MHz (6151 MHz / 6.15 GHz):** **~791 FPS** (Maximum stable throughput)
* +750 MHz: 6251 MHz (~789 FPS — EDC error detection and correction begins adding latency)
* +800+ MHz: visual artifacts / driver crash

Apply dynamically via:
```bash
nvidia-settings -a "[gpu:0]/GPUMemoryTransferRateOffsetAllPerformanceLevels=1300"
```

---

## Quick Install

```bash
git clone https://github.com/besiple/surface-laptop-studio-dgpu-fix.git
cd surface-laptop-studio-dgpu-fix
chmod +x install.sh
sudo ./install.sh
sudo reboot
```

### Applying the Optional `nvidia-powerd` Dynamic Boost Patch

If using `nvidia-open-dkms`:
```bash
sudo patch -p1 -d /usr/src/nvidia-* < patches/nvidia-nvpcf-surface.patch
sudo dkms build -m nvidia/$(nvidia-smi --query-gpu=driver_version --format=csv,noheader) -k $(uname -r) --force
sudo dkms install -m nvidia/$(nvidia-smi --query-gpu=driver_version --format=csv,noheader) -k $(uname -r) --force
sudo systemctl enable --now nvidia-powerd
sudo reboot
```

---

## Verification

After reboot:
```bash
# 1. Verify Deep Sleep in idle (0W / 0MHz):
cat /sys/bus/pci/devices/0000:f3:00.0/power/runtime_status
# Output: suspended

# 2. Verify Full Power under load:
prime-run glmark2
# Output: ~750+ FPS, P0 state, 35W-50W (NOT 10W!)
```
