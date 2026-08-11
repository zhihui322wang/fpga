#!/usr/bin/env python3
"""extract_mac_tx_detail.py — 从 ILA dump 提取 MAC TX 逐周期详细信息"""

import sys
import os

PROBES = {
    "mac_tx_sop": (97, 1), "mac_tx_en": (98, 1), "mac_tx_data": (99, 8),
    "mac_tx_eop": (107, 1), "mac_tx_err": (108, 1),
    "gmii_tx_en": (9, 1), "gmii_txd": (10, 8),
    "cpu_wr_wpkt_push_ind": (112, 1), "cpu_wr_wen_ind": (113, 1),
    "bus_wdata": (115, 32), "cpu_rd_rpkt_pop_ind": (111, 1),
}

def extract(sample, name):
    bit_lo, width = PROBES[name]
    return (sample >> bit_lo) & ((1 << width) - 1)

def parse_dump(filepath):
    samples = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"): continue
            parts = line.split()
            if len(parts) >= 2:
                cleaned = ''.join(c if c in '0123456789abcdefABCDEF' else '0' for c in parts[1])
                samples.append(int(cleaned, 16))
    return samples

def main():
    f = sys.argv[1] if len(sys.argv) > 1 else "ila_dump.txt"
    samples = parse_dump(f)

    # 找 MAC TX SOP
    sop = None
    for i, s in enumerate(samples):
        if extract(s, "mac_tx_sop") == 1:
            sop = i
            break

    if sop is None:
        print("No MAC TX SOP found")
        return

    print(f"MAC TX SOP @ sample {sop} (t={sop*20}ns)")

    # TX PUSH 位置
    for i in range(max(0, sop-30), sop):
        if extract(samples[i], "cpu_wr_wpkt_push_ind") == 1:
            print(f"TX PUSH      @ sample {i} (t={i*20}ns, SOP - {sop-i} = {(sop-i)*20}ns)")

    # 逐周期 MAC TX 数据
    print(f"\n{'Sample':>7} {'Time':>8}  {'SOP':>3} {'EN':>3} {'DATA':>6} {'EOP':>3} {'ERR':>3}  {'GMII_EN':>7} {'GMII_DATA':>10}  Note")
    print("-" * 85)

    in_pkt = False
    byte_cnt = 0
    prev_en = 0
    for i in range(sop-2, min(sop+80, len(samples))):
        s = samples[i]
        tx_sop = extract(s, "mac_tx_sop")
        tx_en = extract(s, "mac_tx_en")
        tx_data = extract(s, "mac_tx_data")
        tx_eop = extract(s, "mac_tx_eop")
        tx_err = extract(s, "mac_tx_err")
        g_en = extract(s, "gmii_tx_en")
        g_data = extract(s, "gmii_txd")

        note = ""
        if tx_sop: note = "← SOP"
        if tx_eop: note = "← EOP"
        if tx_en and not prev_en: note = "EN rise"
        if not tx_en and prev_en: note = "EN fall"
        if tx_err: note += " ⚠ERR"

        print(f"{i:7d} {i*20:7d}ns  {tx_sop:3d} {tx_en:3d} 0x{tx_data:04x}  {tx_eop:3d} {tx_err:3d}  {g_en:7d} 0x{g_data:08x}  {note}")

        if tx_en: byte_cnt += 1
        prev_en = tx_en

    # GMII TX 对齐 (check pipeline delay)
    print(f"\n--- Pipeline Alignment (GMII TX vs MAC TX) ---")
    g_start = None
    for i in range(sop, min(sop+30, len(samples))):
        if extract(samples[i], "gmii_tx_en") == 1:
            g_start = i
            break
    if g_start:
        delay = g_start - sop
        print(f"GMII TX starts @ sample {g_start}, delay = {delay} samples = {delay*20}ns")
        # Check if GMII preamble aligns with MAC byte 0 after preamble
        # GMII starts with 8-byte preamble, MAC starts with Eth header
        # So GMII byte[8] should = MAC byte[0]
        for j in range(20):
            gidx = g_start + j
            midx = sop + j  # approximate
            if gidx < len(samples):
                gb = extract(samples[gidx], "gmii_txd")
                if j >= 8 and midx < len(samples):
                    mb = extract(samples[midx], "mac_tx_data")
                    match = "✓" if gb == mb else "✗"
                    print(f"  GMII[{j}]={(0x55 if j<7 else (0xD5 if j==7 else '--')):>4}  GMII=0x{gb:02x}  MAC[{j-8}]=0x{mb:02x}  {match}")
                else:
                    print(f"  GMII[{j}]=0x{gb:02x}  (preamble)")

    print(f"\nTotal MAC TX bytes: {byte_cnt}")

if __name__ == "__main__":
    main()
