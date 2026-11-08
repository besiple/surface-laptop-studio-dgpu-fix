# Comprehensive Reverse Engineering: Surface Laptop Studio 50W Dynamic Boost on Linux

> **For Collaboration between Antigravity (Local Environment Execution) & Claude Opus (GitHub Architect/Code Analysis)**  
> Target Device: **Microsoft Surface Laptop Studio (Model 1964)**  
> CPU: **Intel Core i7-11370H (Tiger Lake-H35)**  
> dGPU: **NVIDIA GeForce RTX 3050 Ti Laptop GPU (GA107M, PCI `10de:25a0`, Subsystem `1414:0054`)**  
> Baseline TGP: **35W** (`Current Power Limit: 35.00 W`)  
> Advertised Max TGP: **50W** (`Max Power Limit: 50.00 W`)  
> Operating Systems: **Arch Linux (kernel 7.2-surface / linux-surface) + Windows 11 Dual-Boot**

---

## 1. The Core Problem Summary

In Linux, the dGPU runs perfectly with our patches at **35.0W Base TGP** (sustained in games like Minecraft with shaders, 100% GPU utilization, ~63°C).  
However, the **+15W Dynamic Boost** (which allows the dGPU to scale up to **50.0W** when the CPU is running cool at ~7W) is not kicking in because NVIDIA's official Linux daemon **`nvidia-powerd`** fails with:

```text
ERROR! Exception NvPcfApi is not initialized
```

Because `nvidia-powerd` throws this exception and does not enter its dynamic power steering loop (`DLSteer`), the NVIDIA kernel driver (`nvidia.ko` / `nv-kernel.o`) enforces the strict hardware vBIOS baseline of **35.00 W**.

---

## 2. ACPI Decompilation Analysis (`SSDT7` / `SsdtGpu`)

We dumped and disassembled the laptop's actual ACPI tables (`/sys/firmware/acpi/tables/SSDT7`).  
There are two critical devices interacting with graphics power:

### A. Device `\_SB.SGPC` (Hardware ID: `MSHW0216`) — Microsoft Surface Graphics Power Controller

```asl
Device (SGPC)
{
    Name (_HID, "MSHW0216")
    Name (SACT, Zero)       // Sleep Active flag (0 = throttled to 10W upon resume!)
    Name (ENBL, One)        // SMF Boost state
    Name (PWRA, 0xFF88)     // AC power offset (signed 16-bit, 0xFF88 = -120 = -12W)
    Name (PWRD, 0xFFB0)     // DC power offset
    Name (SPWR, Zero)       // Target GPU Boost Power in 1/8W units
    Name (GAPW, 0x23)       // 0x23 (35 dec) = 35W Rated AC TGP
    Name (GAMX, 0x32)       // 0x32 (50 dec) = 50W Max AC TGP
    Name (GDPW, 0x1E)       // 0x1E (30 dec) = 30W Rated DC TGP
    Name (GDMX, 0x23)       // 0x23 (35 dec) = 35W Max DC TGP
```

`SGPC._DSM` (UUID `a99df1bb-b888-42b7-9ced-12810bfe9d90`):
* **Function 7 (`Arg3 = 1`):** Sets `SACT = 1`, clears negative power offsets (`PWRA = 0, PWRD = 0`), emits unthrottle event `Notify (\_SB.PC00.RP09.PXSX, 0xD1)`, but resets `SPWR = 0x0230` (35W default).
* **Function 2 (`Arg3 = SPWR`):** Sets target power `SPWR = Arg3` and fires `Notify (\_SB.NPCF, 0xC0)` into the NVIDIA controller.
  - Setting `Arg3 = 0x0320` configures `SPWR` to **50W** (matching `GAMX = 0x32`).
* **Function 1 (`Arg3 = 1`):** Sets `ENBL = 1` (SMF Boost enabled).

We have automated this sequence in `surface-dgpu-init` via `acpi_call`:
```bash
echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 7 1' > /proc/acpi/call
echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 2 0x0320' > /proc/acpi/call
echo '\_SB.SGPC._DSM bbbf19da988b8b7429ced12810bfe9d90 0 1 1' > /proc/acpi/call
```

---

### B. Device `\_SB.NPCF` (Hardware ID: `NVDA0820`) — NVIDIA Platform Control Framework

* UUID: `36b49710-2483-11e7-9598-0800200c9a66`
* Supported Revision: **`0x0200`** (NVPCF 2.0). If `Arg1 != 0x0200`, returns `0x80000001`.
* Functions in `SSDT7`:
  - **Subfunc 0 (Query Supported):** Returns `Buffer { 0xC7, 0x00, 0x00, 0x00 }` (bits 0, 1, 2, 6, 7 supported).
  - **Subfunc 1 (Static Config):** Returns 27-byte Buffer.
  - **Subfunc 2 (Dynamic Config / PBD2):** 49-byte buffer containing `TPPA` (Total Platform Power AC = `SPWR`).
  - **Subfunc 3:** 61-byte static power limits buffer.
  - **Subfunc 4:** 41-byte static power limits buffer.
  - **Subfunc 5:** 40-byte CPU/thermal limits buffer.
  - **Subfunc 6:** CPU boost update via SystemIO `CFRQ` register.
  - **Subfunc 7:** Sets `ACMX` (AC Max mW), `ACRT` (AC Rated mW), `DCMX`, `DCRT` into `GAPW`/`GAMX`.
  - **Subfunc 8:** **MISSING in ACPI.** On Windows, battery power caps are managed by the Surface SAM EC chip directly.

---

## 3. Windows Drivers Extracted & Inspected

From the dual-boot Windows 11 partition (`C:\Windows\System32\DriverStore\FileRepository\`), we extracted:
* `nvpcf.sys` (NVIDIA Corporation, v32.0.16.2067, 327 KB)
* `SurfaceIhvGpuPowerControllerDriver.sys` (Microsoft, v2.111.139.0, 332 KB)
* `SurfaceSystemManagementFrameworkDriver.sys` (Microsoft SMF Core, v3.137.139.0, 578 KB)
* `SurfaceIhvCpuSmfClient.sys` (Microsoft SMF Tiger Lake Client)

Saved in repo under: `reversing/`

### Key Findings from Windows Reversing:
1. In Windows, `nvpcf.sys` runs inside the **kernel** as a KMDF driver.
2. `nvpcf.sys` attaches to `ACPI\NVDA0820`, registers device interface `{29d92575-4cb9-489e-a9ae-d18efeca7691}`, and directly binds to Microsoft's `SurfaceIhvGpuPowerControllerDriver.sys` via `DMF_CONTEXT_SmfInterface` / `SmfInterface_GPU_GpuInterface`.
3. In Linux, NVIDIA did **NOT** port `nvpcf.sys` to kernel space. Instead, they wrote **`nvidia-powerd`** in user-space, which attempts to communicate with `_SB.NPCF._DSM` through `nv_acpi_dsm_method` in `nv-acpi.c`.

---

## 4. Why `nvidia-powerd` Fails in Linux

In our DKMS kernel module patch (`patches/nvidia-nvpcf-surface.patch`), we already added:
1. Patching Function 0 bitmask from `0xC7` to `0xFF` (and bit 8 in byte 1).
2. Synthesizing the missing Subfunc 8 table (`mock_dc_table`, 21 bytes).

In `dmesg`, we confirm:
```text
NVRM: Patching Surface NVPCF Function 0 mask from 0xc7 to 0xFF
NVRM: Synthesized Surface DC Power Limits Table for NVPCF Subfunc 8
```

However, inside `/usr/bin/nvidia-powerd`:
* At virtual address `0x41e646`:
  ```assembly
  41e641: call   587420
  41e646: lea    0x1dcff3(%rip),%rsi   # "NvPcfApi is not initialized"
  41e64d: mov    %rax,%rdi
  41e650: mov    %rax,%r12
  41e653: call   __cxa_throw
  ```
* Related string table entries at `0x5fb640`–`0x5fb778`:
  - `NvPcfApi is not initialized`
  - `Error in getting the NvPCF static configuration`
  - `Failed to get SysPwrLimitGetInfo`
  - `Invalid DC CPU TDP Cap Command`
  - `workersignal::qboostSetControl`
* Inside the same binary, NVIDIA's dynamic boost engine is named **`DLSteer::NvRm`**:
  ```text
  NvRm: CPU TDP per socket from MSR: %.1fW
  NvRm: Intel TPP - CPU TDP: %.1fW, NVPCF offset: %.1fmW, Final TPP: %.1fW
  NvRm: Power limits - TGP: %.1f-%.1fW, TPP: %.1fW
  NvRm: Intel NVPCF failed (%s), using default TPP: %.1fW
  NvRm: Power monitor not supported on this platform. Using fallback configuration.
  ```

Notice that `DLSteer` actually has fallback code (`using default TPP`, `Using fallback configuration`), but the program never reaches it because `NvPcfApi` throws an unhandled C++ exception during pre-flight initialization.

---

## 5. Specific Questions for Claude Opus Analysis

1. **NVPCF Handshake Details:**  
   Comparing `nvpcf.sys` with the disassembly of `nvidia-powerd`:  
   What specific field in Subfunction 1 (Static Config, 27 bytes) or Subfunction 2 (Dynamic Config `PBD2`, 49 bytes) or Subfunction 3/4 does `nvidia-powerd` validate that causes it to throw `NvPcfApi is not initialized`?
   
2. **Binary Patching `nvidia-powerd`:**  
   Can we NOP out or redirect the `__cxa_throw` at `0x41e653` in `/usr/bin/nvidia-powerd` so that it falls back to default TPP and allows `DLSteer` to run?

3. **Direct NVML / IOCTL Injection:**  
   `nvidia-powerd` communicates with the GPU driver over `/dev/nvidiactl` or private NVML endpoints (`nvidia.powerd.server`).  
   Can we write a lightweight standalone C/Rust daemon that sends the boost target power limit (50W) directly to the NVIDIA driver without needing `nvidia-powerd`?
