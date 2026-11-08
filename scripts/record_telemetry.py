#!/usr/bin/env python3
import time
import subprocess
import sys
import os
import json
from datetime import datetime

def get_cpu_uj():
    try:
        with open('/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj') as f:
            return int(f.read().strip())
    except:
        return 0

def get_cpu_freq():
    try:
        with open('/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq') as f:
            return int(f.read().strip()) // 1000
    except:
        return 0

def get_cpu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone0/temp') as f:
            return int(f.read().strip()) / 1000.0
    except:
        return 0.0

def get_ac_online():
    try:
        for p in ['/sys/class/power_supply/AC/online', '/sys/class/power_supply/ADP1/online', '/sys/class/power_supply/ACAD/online']:
            if os.path.exists(p):
                with open(p) as f:
                    return int(f.read().strip())
    except:
        pass
    return -1

def get_gpu_telemetry():
    try:
        cmd = [
            'nvidia-smi',
            '--query-gpu=power.draw,enforced.power.limit,power.default_limit,power.max_limit,clocks.gr,clocks.mem,temperature.gpu,clocks_throttle_reasons.active',
            '--format=csv,noheader,nounits'
        ]
        out = subprocess.check_output(cmd).decode().strip().split(', ')
        return {
            'power_draw_w': float(out[0]),
            'enforced_limit_w': float(out[1]),
            'default_limit_w': float(out[2]),
            'max_limit_w': float(out[3]),
            'clock_core_mhz': int(out[4]),
            'clock_mem_mhz': int(out[5]),
            'gpu_temp_c': int(out[6]),
            'throttle_reasons': out[7]
        }
    except Exception as e:
        return {'error': str(e)}

def count_powerd_errors(since_ts):
    try:
        cmd = ['journalctl', '-u', 'nvidia-powerd', f'--since=@{int(since_ts)}', '--no-pager']
        out = subprocess.check_output(cmd).decode()
        return out.count('NvPcfApi is not initialized')
    except:
        return -1

def main():
    duration = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    out_file = sys.argv[2] if len(sys.argv) > 2 else None
    
    print(f"[*] Recording telemetry for {duration} seconds (1s interval)...")
    records = []
    
    start_time = time.time()
    last_t = start_time
    last_uj = get_cpu_uj()
    
    for i in range(duration):
        time.sleep(1.0)
        curr_t = time.time()
        curr_uj = get_cpu_uj()
        dt = curr_t - last_t
        cpu_pwr = (curr_uj - last_uj) / dt / 1e6 if dt > 0 else 0
        last_t = curr_t
        last_uj = curr_uj
        
        gpu = get_gpu_telemetry()
        rec = {
            'timestamp': datetime.now().isoformat(),
            'ac_online': get_ac_online(),
            'cpu_power_w': round(cpu_pwr, 2),
            'cpu_freq_mhz': get_cpu_freq(),
            'cpu_temp_c': get_cpu_temp(),
            'gpu': gpu
        }
        records.append(rec)
        print(f"[{i+1}/{duration}] GPU: {gpu.get('power_draw_w', 0):.1f}W (Lim: {gpu.get('enforced_limit_w', 0):.1f}W, {gpu.get('clock_core_mhz', 0)}MHz) | CPU: {cpu_pwr:.1f}W ({rec['cpu_freq_mhz']}MHz, {rec['cpu_temp_c']:.1f}°C)")

    err_count = count_powerd_errors(start_time)
    print(f"\n[*] Summary:")
    gpu_pwrs = [r['gpu'].get('power_draw_w', 0) for r in records if 'power_draw_w' in r['gpu']]
    gpu_lims = [r['gpu'].get('enforced_limit_w', 0) for r in records if 'enforced_limit_w' in r['gpu']]
    cpu_pwrs = [r['cpu_power_w'] for r in records]
    
    print(f"  GPU Power Draw:    avg={sum(gpu_pwrs)/len(gpu_pwrs):.2f}W, max={max(gpu_pwrs):.2f}W")
    print(f"  GPU Enforced Limit: avg={sum(gpu_lims)/len(gpu_lims):.2f}W, max={max(gpu_lims):.2f}W")
    print(f"  CPU Power Draw:    avg={sum(cpu_pwrs)/len(cpu_pwrs):.2f}W, max={max(cpu_pwrs):.2f}W")
    print(f"  nvidia-powerd exceptions during test: {err_count}")
    
    if out_file:
        with open(out_file, 'w') as f:
            json.dump({'records': records, 'summary': {
                'avg_gpu_power_w': sum(gpu_pwrs)/len(gpu_pwrs),
                'max_gpu_power_w': max(gpu_pwrs),
                'avg_gpu_limit_w': sum(gpu_lims)/len(gpu_lims),
                'max_gpu_limit_w': max(gpu_lims),
                'avg_cpu_power_w': sum(cpu_pwrs)/len(cpu_pwrs),
                'max_cpu_power_w': max(cpu_pwrs),
                'powerd_exceptions': err_count
            }}, f, indent=2)
        print(f"[*] Saved telemetry to {out_file}")

if __name__ == '__main__':
    main()
