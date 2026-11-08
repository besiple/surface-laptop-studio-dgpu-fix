# Surface Laptop Studio dGPU 50W Power Uncapped — Final Report & Solution

**Date**: 2026-11-08  
**Hardware**: Microsoft Surface Laptop Studio (Model 1964)  
**CPU**: Intel Core i7-11370H  
**GPU**: NVIDIA GeForce RTX 3050 Ti Mobile (GA107M, PCI `10de:25a0`, Subsystem `1414:0054`)  
**Kernel**: `linux-surface` 7.2.15-arch1-1-surface  
**Driver**: NVIDIA Open GPU Kernel Modules 615.78.08  

---

## 1. Executive Summary

We have successfully unlocked the NVIDIA RTX 3050 Ti Mobile GPU on the Microsoft Surface Laptop Studio from its default **35.0 W lock to its full 50.0 W maximum TGP**.

- **Verified with `nvidia-smi -q -d POWER`**:
  ```
  GPU Ceiling Power Limit
      Current Power Limit    : 50.00 W  (previously locked at 35.00 W)
      Default Power Limit    : 35.00 W
      Min Power Limit        : 1.00 W
      Max Power Limit        : 50.00 W
  ```
- **Verified live in game (Minecraft shaders)**:
  - Previously: capped at **34.0 W** at **1216–1243 MHz**.
  - Now: drawing **43.3+ W** at **1687–1740 MHz** (boost headroom fully active up to 50W).

---

## 2. Root Cause Analysis

### The Missing Microsoft Power Controller (`MSHW0216`)

On Microsoft Surface Laptop Studio, power steering is arbitrated through an ACPI device:
`\_SB.SGPC` (Hardware ID `MSHW0216`, Surface GPU Power Controller).

In ACPI table `SSDT7.dsl`:
```asl
Device (SGPC)
{
    Name (_HID, "MSHW0216")
    Name (SACT, Zero)    // Active flag
    Name (ENBL, One)     // SMF Boost Enable
    Name (PWRA, 0xFF88)  // AC Power Offset: 0xFF88 = -120 (-15.0W!)
    Name (PWRD, 0xFFB0)  // DC Power Offset: 0xFFB0 = -80 (-10.0W!)
    Name (SPWR, Zero)    // Target TGP power: 0W
    Name (GAPW, 0x23)    // AC Base TGP: 35W (0x23 = 35)
    Name (GAMX, 0x32)    // AC Max TGP: 50W (0x32 = 50)
    ...
```

At system boot:
1. SBIOS initializes `PWRA = 0xFF88` (`-120` in signed 16-bit).
2. NVPCF Function 2 passes `PGSO = PWRA` (`-120`) to the NVIDIA driver as `ctgpOffsetmW`.
3. In NVIDIA driver (`client_resource.c`):
   ```c
   pParams->ctgpOffsetmW = (NvS32)NVPCF_DYNAMIC_PARAMS_2X_POWER_UNIT_MW *
       (NvS16)DRF_VAL(PCF_DYNAMIC_PARAMS_COMMON_2X, _OUTPUT_PARAM0, _CMD0_CTGP_AC_OFFSET, commonOut.param0);
   ```
   Since `NVPCF_DYNAMIC_PARAMS_2X_POWER_UNIT_MW = 125 mW`, `-120 * 125 mW = -15,000 mW (-15 W)`.
4. Windows loads the proprietary Microsoft `MSHW0216` driver, which activates `SGPC`, removes the negative offset, and configures 50W.
5. **Linux has no driver for `MSHW0216`**. Therefore, `SACT` stayed `0`, `PWRA` remained at `-15W` (or 0 offset), and the GPU remained locked at the 35W base floor forever.

---

## 3. The Resolution

By interacting directly with `\_SB.SGPC._DSM` (UUID `bbbf19da-988b-8b74-29ce-d12810bfe9d90`):

1. **Function 7 (`Arg3 = 1`)**:
   Activates `SACT = 1`, initializes firmware arbiter, clears negative offsets.
2. **Function 3 (`Arg3 = 0x78 = 120`)**:
   Sets `PWRA = +120` (`+120 * 125 mW = +15,000 mW = +15 Watts` cTGP boost offset!).
3. **Function 2 (`Arg3 = 0x0320 = 800`)**:
   Sets target TGP `SPWR = 800 * 0.0625 W = 50.0 Watts` and sends ACPI notification `0xC0` to `\_SB.PC00.PEG0.PEGP.NPCF`.
4. **Function 1 (`Arg3 = 1`)**:
   Enables `ENBL = 1`.

### Kernel Response
When notification `0xC0` arrives:
1. `nv_acpi_nvpcf_event()` intercepts `0xC0` and notifies the core RM.
2. Core RM evaluates NVPCF Function 2, reading `ctgpOffsetmW = +15,000 mW`.
3. RM sends `NV2080_CTRL_CMD_INTERNAL_PMGR_PFM_REQ_HNDLR_CONFIGURE_TURBO_V2` to the GPU PMGR.
4. The hardware instantly uncaps `Current Power Limit` from **35.00 W to 50.00 W**.

---

## 4. Automation: Permanent Persistence Across Boots & Sleep

To ensure the 50W configuration is applied automatically at every boot and resume from sleep:

### Script: `/usr/local/bin/surface-dgpu-50w.sh`
```bash
#!/bin/bash
set -euo pipefail

modprobe acpi_call 2>/dev/null || true

call_acpi() {
    echo "$1" > /proc/acpi/call
}

call_acpi '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 7 1'
call_acpi '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 3 0x78'
call_acpi '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 2 0x0320'
call_acpi '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 1 1'
```

### Systemd Unit: `/etc/systemd/system/surface-dgpu-power.service`
```ini
[Unit]
Description=Surface Laptop Studio dGPU 50W Power Uncapper
After=systemd-modules-load.service
Before=nvidia-powerd.service
WantedBy=multi-user.target sleep.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/surface-dgpu-50w.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target sleep.target
```

Enabled and active via:
`systemctl enable --now surface-dgpu-power.service`
