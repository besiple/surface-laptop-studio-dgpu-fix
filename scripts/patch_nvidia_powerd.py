#!/usr/bin/env python3
"""
Patch nvidia-powerd binary to bypass uninitialized DC controller exceptions on Microsoft Surface.
Replaces the 5 __cxa_throw jump targets in NvPcfApi handlers with clean returns.
"""
import sys
import os
import shutil

PATTERNS = [
    (b'\x0f\x84\x7b\xaa\xea\xff', b'\x0f\x84\x40\x00\x00\x00'),
    (b'\x0f\x84\x58\xa9\xea\xff', b'\x0f\x84\xca\x00\x00\x00'),
    (b'\x0f\x88\x9a\xa8\xea\xff', b'\x0f\x88\xbf\x00\x00\x00'),
    (b'\x0f\x84\x47\xa6\xea\xff', b'\x0f\x84\x63\x00\x00\x00'),
    (b'\x0f\x88\x0a\xa6\xea\xff', b'\x0f\x88\x58\x00\x00\x00'),
    (b'\x0f\x84\xf5\xa6\xea\xff', b'\x0f\x84\x68\x00\x00\x00'),
    (b'\x0f\x88\xb8\xa6\xea\xff', b'\x0f\x88\x5d\x00\x00\x00'),
    (b'\x0f\x84\x31\xa8\xea\xff', b'\x0f\x84\x55\x00\x00\x00'),
    (b'\x0f\x88\xd1\xa7\xea\xff', b'\x0f\x88\x4a\x00\x00\x00'),
]

def patch_file(bin_path):
    if not os.path.exists(bin_path):
        print(f"File not found: {bin_path}")
        return False

    with open(bin_path, 'rb') as f:
        data = f.read()

    # Check if already patched
    already_patched = True
    for _, rep in PATTERNS:
        if rep not in data:
            already_patched = False
            break
    if already_patched:
        print(f"{bin_path} is already patched.")
        return True

    # Backup
    backup_path = bin_path + ".orig"
    if not os.path.exists(backup_path):
        shutil.copy2(bin_path, backup_path)
        print(f"Created backup at {backup_path}")

    patched_count = 0
    for pat, rep in PATTERNS:
        if pat in data:
            data = data.replace(pat, rep, 1)
            patched_count += 1

    if patched_count == 0:
        print(f"No patch patterns found in {bin_path}. Version mismatch or already modified.")
        return False

    tmp_path = bin_path + ".tmp"
    with open(tmp_path, 'wb') as f:
        f.write(data)
    os.chmod(tmp_path, 0o755)
    os.replace(tmp_path, bin_path)
    print(f"Successfully applied {patched_count} patches to {bin_path}")
    return True

if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else '/usr/bin/nvidia-powerd'
    patch_file(target)
