# Surface Laptop Studio dGPU Fix (10W Bug, D3cold & 50W Unlock)

Fixes NVIDIA RTX 3050 Ti power management on the **Microsoft Surface Laptop Studio 1 (Model 1964)** under Linux:

- **10W Sleep Throttle Fix:** Prevents the dGPU from waking out of `D3cold` stuck at 10W (`P8` state).
- **D3cold Idle Sleep:** Enables Runtime D3 (`0W` / `0 MHz` idle draw) with Wayland sleep stability.
- **50W Dynamic Boost (Optional):** Unlocks the full 50W TGP ceiling on AC power (up from the 35W base limit) via ACPI `SGPC` steering + an optional `nvidia-open-dkms` patch.
- **+650 MHz VRAM Overclock (Optional):** Applies a 6.15 GHz memory clock offset via NVML natively on Wayland (installer prompts interactively).

> **Note:** Tested on Surface Laptop Studio 1 (i7-11370H + RTX 3050 Ti). Surface Laptop Studio 2 is currently untested.

---

## Quick Start

### Requirements
- `linux-surface` kernel (recommended for full Surface ACPI support).
- **AC charger connected** for 50W mode (on battery, the Surface EC hardware clamps the GPU to 35W).
- `nvidia-open-dkms` — only required if you opt into the 50W Dynamic Boost patch. Standard vendor drivers work fine for the 10W fix + 35W stock TGP.

### Install
```bash
git clone https://github.com/besiple/surface-laptop-studio-dgpu-fix.git
cd surface-laptop-studio-dgpu-fix
chmod +x install.sh
sudo ./install.sh
sudo reboot
```

Running `sudo ./install.sh` starts interactive mode and prompts for optional features (50W Dynamic Boost patch and +650 MHz VRAM overclock).

For scripted / non-interactive installs, pass flags directly:
```bash
# Full 50W Dynamic Boost patch:
sudo ./install.sh --nvpcf-patch

# Stock drivers only (fixes 10W bug at factory 35W TGP):
sudo ./install.sh --no-nvpcf-patch
```

---

## Benchmarks

Tested on **Surface Laptop Studio (Model 1964)** (i7-11370H, RTX 3050 Ti Mobile) running *Minecraft + BSL / Iris Shaders* on Arch Linux (`linux-surface` 7.2.15 & 7.3.4, `nvidia-open-dkms` 620.73.04):

| Metric | Stock (35W Base) | Unlocked (50W TGP) | Delta |
| :--- | :---: | :---: | :---: |
| **GPU Power** | 34.0 W | **47.0 – 50.0 W** | +38% to +47% |
| **Core Clock** | 1268 MHz | **1510 – 1740 MHz** | +19% to +37% |
| **Framerate** | 33 FPS | **40 – 51 FPS** | +21% to +55% |
| **Frametime** | 30.1 ms | **19.8 – 24.9 ms** | -17% to -34% |
| **Temperature** | 65°C | **69 – 72°C** | +4 to +7°C |

### Before: 35W Base Lock (34W / 1268 MHz / 33 FPS)
![Before: 35W Lock](assets/sls_benchmark_35w_lock.jpg)

### After: 50W TGP Unlocked (47–50W / 1510 MHz / 40+ FPS)
![After: 50W Unlocked](assets/sls_benchmark_50w_unlocked.jpg)

---

## Verification

After rebooting, confirm everything is active:

```bash
# 1. Check TGP ceiling (50.00 W with NVPCF patch, 35.00 W on stock driver):
nvidia-smi -q -d POWER | grep -A 5 "GPU Ceiling Power Limit"

# 2. Check D3cold deep sleep in idle (should print "suspended"):
cat /sys/bus/pci/devices/0000:f3:00.0/power/runtime_status

# 3. Check live power draw in-game:
# Use any GPU-bound workload (e.g. Minecraft with shaders, Steam games with MANGOHUD=1, or Unigine Superposition)
```

---

## Driver Updates & Uninstall

### After an NVIDIA Driver Update
Updating `nvidia-open-dkms` overwrites `/usr/src/nvidia-*` with unpatched upstream sources:
- **Re-apply 50W Boost:** Run `sudo ./install.sh --nvpcf-patch` (the script validates compatibility with `patch --dry-run` before touching files).
- **Do nothing:** The system boots normally on the unpatched driver — the 10W fix, D3cold idle, and 35W TGP keep working.

### Revert NVPCF Patch to Stock Driver
```bash
sudo pacman -S nvidia-open-dkms                            # Arch Linux
sudo dnf reinstall akmod-nvidia-open                       # Fedora
sudo apt install --reinstall nvidia-kernel-source-open     # Ubuntu / Debian
```

### Full Uninstall
Removes all scripts, systemd units, udev/modprobe rules, unmasks `nvidia-powerd`, resets ACPI registers to 35W, and rebuilds initramfs:
```bash
sudo ./uninstall.sh
```

---

## How It Works (ACPI Reverse Engineering)

<details>
<summary><b>Click to expand DSDT / SSDT7 analysis (MSHW0216 & NVPCF)</b></summary>

### 1. Why the GPU Locks to 10W After D3cold
In `DSDT` / `SSDT7`, the power resource `PRPD._ON` checks `\_SB.SGPC.SACT` (`MSHW0216` — Microsoft Surface Graphics Power Controller):

```asl
PowerResource (PRPD, 0x00, 0x0000)
{
    Method (_ON, 0, Serialized)
    {
        ...
        If ((ToInteger (\_SB.SGPC.SACT) == One))
        {
            Notify (\_SB.SGPC, 0x81) // Normal wake
        }
        Else
        {
            Notify (\_SB.PC00.RP09.PXSX, 0xD5) // Emergency 10W throttle
        }
    }
}
```

On Windows, `SurfaceDgpuPwr.sys` sets `SACT = 1`. On Linux, no driver exists for `MSHW0216`, so `SACT` stays `0` and every wake from D3cold fires `0xD5`, clamping the GPU to 10W.

### 2. Why TGP Stops at 35W Instead of 50W
`\_SB.SGPC` boots with a `-15W` AC power offset (`PWRA = 0xFF88 = -120`, in 125 mW units):

```asl
Name (PWRA, 0xFF88)  // AC Power Offset: -120 * 125 mW = -15.0W
Name (SPWR, Zero)    // Target TGP: 0W
Name (GAPW, 0x23)    // AC Base TGP: 35W
Name (GAMX, 0x32)    // AC Max TGP: 50W
```

Invoking `\_SB.SGPC._DSM` (`bbbf19da-988b-8b74-29ce-d12810bfe9d90`) fixes both issues:
- **Fn 7 (`Arg3 = 1`):** Sets `SACT = 1`, clears negative offsets, fires unthrottle `0xD1`.
- **Fn 3 (`Arg3 = 0x78`):** Sets `PWRA = +120` (`+15,000 mW` cTGP boost offset).
- **Fn 2 (`Arg3 = 0x0320`):** Sets `SPWR = 50.0W` (`800 * 0.0625W`) and notifies `NPCF` (`0xC0`).
- **Fn 1 (`Arg3 = 1`):** Enables SMF Boost.

With the optional NVPCF patch in `patches/nvidia-nvpcf-surface.patch`, the NVIDIA driver processes the `0xC0` event, calls `CONFIGURE_TURBO_V2`, and raises `Current Power Limit` to `50.00 W`.

Full writeups and dumps:
- [`docs/SGPC_50W_UNLOCKED.md`](docs/SGPC_50W_UNLOCKED.md)
- [`docs/REVERSE_ENGINEERING_50W.md`](docs/REVERSE_ENGINEERING_50W.md)
- [`docs/acpi/SSDT7.dsl`](docs/acpi/SSDT7.dsl)

</details>

---

## Credits & License

- **besiple** — Research, ACPI reverse engineering, hardware validation, and maintenance.
- **Gemini 3.8 Antigravity & Claude Opus 5.5** — Collaborative ACPI analysis, driver patching, and disassembly.

Licensed under the [MIT License](LICENSE) — Copyright (c) 2026 **besiple**. Attribution and a link back to this repository must be retained in derivatives per the MIT License.
