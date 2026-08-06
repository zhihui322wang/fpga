#!/usr/bin/env python3
"""ila_dump_to_vcd.py — 将 ILA 仿真回读数据转换为 GTKWave 可打开的 VCD 文件

用法:
    python3 ila_dump_to_vcd.py ila_dump.txt ila_wave.vcd

输入: ila_dump.txt (由 tb_fast.v 的 ila_readback_and_dump 任务生成)
输出: ila_wave.vcd (标准 VCD 格式, 可用 gtkwave 打开)
"""

import sys
import os

# ── 探针定义 (与 signals.json / webserver_cpu_top.v 保持一致) ──
PROBES = [
    {"name": "gmii_rx_dv",    "width": 1,  "bit_lo": 0},
    {"name": "gmii_rxd",      "width": 8,  "bit_lo": 1},
    {"name": "gmii_tx_en",    "width": 1,  "bit_lo": 9},
    {"name": "gmii_txd",      "width": 8,  "bit_lo": 10},
    {"name": "mac_rx_sop",    "width": 1,  "bit_lo": 18},
    {"name": "mac_rx_en",     "width": 1,  "bit_lo": 19},
    {"name": "mac_rx_data",   "width": 8,  "bit_lo": 20},
    {"name": "mac_rx_eop",    "width": 1,  "bit_lo": 28},
    {"name": "bus_req",       "width": 1,  "bit_lo": 29},
    {"name": "bus_rhwl",      "width": 1,  "bit_lo": 30},
    {"name": "bus_address",   "width": 32, "bit_lo": 31},
    {"name": "bus_rdata",     "width": 32, "bit_lo": 63},
    {"name": "bus_ack",       "width": 1,  "bit_lo": 95},
]

# VCD 标识符: 每个信号一个唯一短标识符 (用于 VCD 值变化)
# 使用可打印 ASCII: !"#$%&'()*+,-./0-9:;<=>?@A-Z[\]^_`a-z
VCD_CHARS = [chr(c) for c in range(33, 127)]  # 33='!', 126='~'


def make_vcd_id(idx):
    """生成 VCD 标识符 (支持最多 94 个信号, 超出用多字符)"""
    if idx < len(VCD_CHARS):
        return VCD_CHARS[idx]
    # 双字符
    hi = (idx - len(VCD_CHARS)) // len(VCD_CHARS)
    lo = (idx - len(VCD_CHARS)) % len(VCD_CHARS)
    return VCD_CHARS[hi] + VCD_CHARS[lo]


def extract_probe(sample_int, bit_lo, width):
    """从 96-bit 样本中提取指定探针的值"""
    mask = (1 << width) - 1
    return (sample_int >> bit_lo) & mask


def format_vcd_value(val, width):
    """将值格式化为 VCD 二进制字符串"""
    if width == 1:
        return str(val)
    return f"b{val:0{width}b}"


def parse_dump_file(filepath):
    """解析 ila_dump.txt, 返回样本列表 (每个样本为 int)"""
    samples = []
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                try:
                    sample_idx = int(parts[0])
                    sample_val = int(parts[1], 16)
                    samples.append(sample_val)
                except ValueError:
                    continue
    return samples


def generate_vcd(samples, output_path, sample_period_ns=8):
    """根据样本数据生成 VCD 文件"""
    if not samples:
        print("ERROR: No samples to convert!")
        return

    total_width = sum(p["width"] for p in PROBES)
    num_probes = len(PROBES)

    # 分配 VCD ID
    probe_ids = {}
    for i, p in enumerate(PROBES):
        probe_ids[p["name"]] = make_vcd_id(i)

    with open(output_path, "w") as f:
        # VCD 头部
        f.write("$date\n\tILA Capture Dump Conversion\n$end\n")
        f.write("$version\n\tfpga_ila sim dump to VCD\n$end\n")
        f.write(f"$timescale 1ns $end\n")

        # 信号声明
        f.write("$scope module ila_capture $end\n")
        for p in PROBES:
            vid = probe_ids[p["name"]]
            f.write(f"$var wire {p['width']} {vid} {p['name']} $end\n")
        f.write("$upscope $end\n")
        f.write("$enddefinitions $end\n")

        # 初始化 (全部为 0)
        f.write("#0\n$dumpvars\n")
        for p in PROBES:
            vid = probe_ids[p["name"]]
            if p["width"] == 1:
                f.write(f"0{vid}\n")
            else:
                f.write(f"b{'0' * p['width']} {vid}\n")
        f.write("$end\n")

        # 输出每个样本
        prev_values = {p["name"]: 0 for p in PROBES}
        for idx, sample in enumerate(samples):
            time_ps = idx * sample_period_ns * 1000  # ns → ps equivalent... no, VCD uses ns here
            # Actually VCD time is in the timescale units. With $timescale 1ns, time is in ns.
            time_ns = idx * sample_period_ns

            # 检查每个信号是否变化
            changes = []
            for p in PROBES:
                val = extract_probe(sample, p["bit_lo"], p["width"])
                if val != prev_values[p["name"]]:
                    changes.append((p, val))
                    prev_values[p["name"]] = val

            if changes:
                f.write(f"#{time_ns}\n")
                for p, val in changes:
                    vid = probe_ids[p["name"]]
                    f.write(f"{format_vcd_value(val, p['width'])}{vid}\n")

        # 最后一个时间点 (加一个空拍)
        last_time = len(samples) * sample_period_ns
        f.write(f"#{last_time}\n")

    print(f"VCD written: {output_path}")
    print(f"  Samples: {len(samples)}")
    print(f"  Probes:  {num_probes}, total {total_width} bits")
    print(f"  Duration: {len(samples) * sample_period_ns} ns")
    print(f"  Open with: gtkwave {output_path}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else "ila_wave.vcd"

    if not os.path.exists(input_file):
        print(f"ERROR: Input file not found: {input_file}")
        print("Run the simulation first: make run")
        sys.exit(1)

    print(f"Reading: {input_file}")
    samples = parse_dump_file(input_file)
    print(f"Parsed {len(samples)} samples")

    if samples:
        generate_vcd(samples, output_file, sample_period_ns=20)  # 仿真中 MMCM bypass → clk_125m=50MHz=20ns

        # 也输出前几个样本供预览
        print("\n--- First 5 samples preview ---")
        for i in range(min(5, len(samples))):
            s = samples[i]
            print(f"  [{i}] gmii_rxd=0x{(s>>1)&0xFF:02x} mac_rx_data=0x{(s>>20)&0xFF:02x} "
                  f"bus_addr=0x{(s>>31)&0xFFFFFFFF:08x}")


if __name__ == "__main__":
    main()
