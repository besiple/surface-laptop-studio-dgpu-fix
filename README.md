# Surface Laptop Studio dGPU 10W Bug Fix & D3cold Enabler

## The Problem
On the Microsoft Surface Laptop Studio (and Surface Laptop Studio 2) running Linux, enabling NVIDIA Runtime D3 (RTD3 / D3cold) via `NVreg_DynamicPowerManagement=0x01` or `0x02` causes the discrete GPU (e.g. RTX 3050 Ti Mobile) to wake up throttled down to a hard **10W power limit (P8 state)**, resulting in unplayable ~10-15 FPS in games and 3D workloads.

Because of this, the Linux-Surface community has historically recommended completely disabling dynamic power management (`NVreg_DynamicPowerManagement=0x00`), keeping the GPU awake 24/7 at ~3.5W–10W and draining laptop battery.

---

## Root Cause Discovered (ACPI Reverse Engineering)

By disassembling the ACPI tables (`DSDT` and `SSDT7`), we identified the exact cause:

1. In `SSDT7`, discrete GPU power rail transitions are governed by the `PRPD` power resource. When the dGPU wakes up, method `_ON` executes:
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
3. At boot, `SACT` is initialized to `Zero`. In addition, negative power offsets (`PWRA = 0xFF88`, `PWRD = 0xFFB0`) are applied to the NVIDIA driver via `NPCF`.
4. On Windows, Microsoft's proprietary `SurfaceDgpuPwr.sys` driver initializes `MSHW0216` by calling its `_DSM` (UUID: `a99df1bb-b888-42b7-9ced-12810bfe9d90`, Function `0x07`, `Arg3 = 1`).
   This sets `SACT = 1`, clears the negative power offsets (`PWRA = 0`, `PWRD = 0`), and issues an unthrottle event `0xD1` to the GPU.
5. **On Linux, NO kernel driver existed for `MSHW0216`**. `SACT` was left at `0`.
   As a consequence, **every time the GPU resumed from D3cold, ACPI sent notification `0xD5` to the NVIDIA driver, forcing the card down to 10 Watts!**

---

## The Fix

By using `acpi_call`, we initialize `MSHW0216` at boot time and on system resume:
1. `_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 7 1`
   * Sets `SACT = 1`
   * Clears negative power offsets
   * Sends unthrottle event `0xD1`
2. `_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 1 1`
   * Enables SMF / Dynamic boost parameters

Now, when the GPU wakes from D3cold, `PRPD._ON` sees `SACT == 1`, **does NOT send `0xD5`**, and the GPU runs at its full 35W/50W TGP!

---

## Quick Install

```bash
chmod +x install.sh
sudo ./install.sh
sudo reboot
```

## Verification

After reboot:

1. **Verify Idle Sleep (0W / 0MHz):**
   ```bash
   cat /sys/bus/pci/devices/0000:f3:00.0/power/runtime_status
   # Output: suspended
   ```
2. **Verify Full Power Under Load:**
   ```bash
   prime-run glmark2
   # Output: ~750+ FPS, P0 state, 35W power limit (NOT 10W!)
   ```
