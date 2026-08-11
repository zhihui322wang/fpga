#!/usr/bin/env python3
"""analyze_mac_tx.py — 从 ILA dump 提取 MAC TX 信号并验证发包时序

验证项目:
1. mac_tx_sop 脉冲宽度 (应为 1 cycle)
2. mac_tx_en 持续期间 → 包长度
3. mac_tx_data 字节流内容 (Ethernet + IP + TCP 头校验)
4. mac_tx_eop 与 mac_tx_en 下降沿的时序关系
5. gmii_tx_en/gmii_txd 与 mac_tx_* 的流水线延迟
6. 帧间隙 (IFG) 检查

用法:
    python3 analyze_mac_tx.py [ila_dump.txt]
"""

import sys
import os

# ── 探针定义 (与 signals.json 一致) ──
PROBES = {
    # RX side
    "gmii_rx_dv":           (0, 1),
    "gmii_rxd":             (1, 8),
    # TX side — GMII
    "gmii_tx_en":           (9, 1),
    "gmii_txd":             (10, 8),
    # RX side — MAC
    "mac_rx_sop":           (18, 1),
    "mac_rx_en":            (19, 1),
    "mac_rx_data":          (20, 8),
    "mac_rx_eop":           (28, 1),
    # CPU bus
    "bus_req":              (29, 1),
    "bus_rhwl":             (30, 1),
    "bus_address":          (31, 32),
    "bus_rdata":            (63, 32),
    "bus_ack":              (95, 1),
    # TX side — GMII error
    "gmii_tx_er":           (96, 1),
    # TX side — MAC
    "mac_tx_sop":           (97, 1),
    "mac_tx_en":            (98, 1),
    "mac_tx_data":          (99, 8),
    "mac_tx_eop":           (107, 1),
    "mac_tx_err":           (108, 1),
    # CPU FIFO
    "cpu_rd_empty":         (109, 1),
    "cpu_wr_full":          (110, 1),
    "cpu_rd_rpkt_pop_ind":  (111, 1),
    "cpu_wr_wpkt_push_ind": (112, 1),
    "cpu_wr_wen_ind":       (113, 1),
    "cpu_rd_ren":           (114, 1),
    # CPU bus write data
    "bus_wdata":            (115, 32),
    "led_val":              (147, 4),
}

SAMPLE_PERIOD_NS = 20  # 50MHz ILA clock


def extract(sample, name):
    """从样本 int 中提取探针值"""
    bit_lo, width = PROBES[name]
    mask = (1 << width) - 1
    return (sample >> bit_lo) & mask


def parse_dump(filepath):
    """解析 ila_dump.txt"""
    samples = []
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                hex_str = parts[1]
                cleaned = ''.join(
                    c if c in '0123456789abcdefABCDEF' else '0'
                    for c in hex_str
                )
                samples.append(int(cleaned, 16))
    return samples


def find_pulses(samples, signal_name):
    """找信号的上升沿位置 (0→1)"""
    edges = []
    prev = 0
    for i, s in enumerate(samples):
        cur = extract(s, signal_name)
        if cur == 1 and prev == 0:
            edges.append(i)
        prev = cur
    return edges


def find_falling_edges(samples, signal_name):
    """找信号的下降沿位置 (1→0)"""
    edges = []
    prev = 0
    for i, s in enumerate(samples):
        cur = extract(s, signal_name)
        if cur == 0 and prev == 1:
            edges.append(i)
        prev = cur
    return edges


def analyze_mac_tx_packet(samples, sop_idx):
    """分析从 sop_idx 开始的 MAC TX 包

    返回: {
        'sop_sample': int,
        'eop_sample': int,
        'data_bytes': [int, ...],
        'errors': [str, ...],
        'gmii_delay': int (cycles),
        'has_error': bool,
    }
    """
    result = {
        'sop_sample': sop_idx,
        'eop_sample': None,
        'data_bytes': [],
        'errors': [],
        'gmii_delay': None,
        'has_error': False,
    }

    # 1. 验证 SOP 脉冲宽度 = 1
    sop_width = 0
    for i in range(sop_idx, min(sop_idx + 5, len(samples))):
        if extract(samples[i], "mac_tx_sop") == 1:
            sop_width += 1
        else:
            break
    if sop_width != 1:
        result['errors'].append(f"SOP pulse width = {sop_width} cycles (expected 1)")

    # 2. 收集数据字节: mac_tx_en=1 期间的 mac_tx_data
    i = sop_idx
    # mac_tx_en 在 SOP 同一拍或下一拍拉高
    en_start = None
    for offset in range(3):
        if extract(samples[sop_idx + offset], "mac_tx_en") == 1:
            en_start = sop_idx + offset
            break
    if en_start is None:
        result['errors'].append("mac_tx_en never asserted after SOP!")
        return result

    # 从 en_start 开始收集数据直到 en=0
    en_end = None
    for i in range(en_start, len(samples)):
        en_val = extract(samples[i], "mac_tx_en")
        if en_val == 1:
            result['data_bytes'].append(extract(samples[i], "mac_tx_data"))
        else:
            en_end = i
            break

    if en_end is None:
        result['errors'].append("mac_tx_en never de-asserted (sim ended?)")
        return result

    # 3. 验证 EOP
    eop_found = False
    for offset in range(-2, 3):  # EOP 通常在 en 下降沿附近
        idx = en_end + offset
        if 0 <= idx < len(samples):
            if extract(samples[idx], "mac_tx_eop") == 1:
                result['eop_sample'] = idx
                eop_found = True
                # 验证 EOP 脉冲宽度
                eop_width = 0
                for j in range(idx, min(idx + 5, len(samples))):
                    if extract(samples[j], "mac_tx_eop") == 1:
                        eop_width += 1
                    else:
                        break
                if eop_width != 1:
                    result['errors'].append(f"EOP pulse width = {eop_width} cycles (expected 1)")
                break

    if not eop_found:
        result['errors'].append(f"EOP not found near en_end={en_end}!")

    # 4. 检查 mac_tx_err
    for i in range(sop_idx, (result['eop_sample'] or en_end) + 2):
        if extract(samples[i], "mac_tx_err") == 1:
            result['has_error'] = True
            result['errors'].append(f"mac_tx_err=1 at sample {i}!")
            break

    # 5. 找 GMII TX 对应包 (流水线延迟)
    # gmii_tx_en 应该在 mac_tx_sop 之后几拍出现
    for delay in range(1, 30):
        gidx = sop_idx + delay
        if gidx < len(samples) and extract(samples[gidx], "gmii_tx_en") == 1:
            result['gmii_delay'] = delay
            break

    return result


def verify_packet_content(data_bytes, label="MAC_TX"):
    """验证 Ethernet + IP + TCP 报头字段"""
    issues = []

    if len(data_bytes) < 14:
        issues.append(f"Packet too short: {len(data_bytes)} bytes (< 14 Eth header)")
        return issues

    # EtherType
    ethtype = (data_bytes[12] << 8) | data_bytes[13]
    if ethtype not in (0x0800, 0x0806, 0x86DD):
        issues.append(f"EtherType = 0x{ethtype:04x} (expected 0x0800 IPv4)")
    else:
        etype_name = {0x0800: "IPv4", 0x0806: "ARP", 0x86DD: "IPv6"}.get(ethtype, "?")
        print(f"  EtherType: 0x{ethtype:04x} ({etype_name})")

    if ethtype == 0x0800 and len(data_bytes) >= 34:
        # IP header
        ver_ihl = data_bytes[14]
        version = ver_ihl >> 4
        ihl = ver_ihl & 0xF
        print(f"  IP Version={version}, IHL={ihl} (header={ihl*4}B)")

        total_len = (data_bytes[16] << 8) | data_bytes[17]
        print(f"  IP Total Length: {total_len}")

        protocol = data_bytes[23]
        proto_name = {1: "ICMP", 6: "TCP", 17: "UDP"}.get(protocol, str(protocol))
        print(f"  IP Protocol: {protocol} ({proto_name})")

        # IP checksum
        ip_cksum = (data_bytes[24] << 8) | data_bytes[25]
        print(f"  IP Checksum: 0x{ip_cksum:04x}")

        # IP addresses
        src_ip = '.'.join(str(b) for b in data_bytes[26:30])
        dst_ip = '.'.join(str(b) for b in data_bytes[30:34])
        print(f"  IP Src: {src_ip} → Dst: {dst_ip}")

        if version != 4:
            issues.append(f"IP version = {version} (expected 4)")
        if protocol == 6 and len(data_bytes) >= 54:
            # TCP header
            tcp_off = 14 + ihl * 4
            src_port = (data_bytes[tcp_off] << 8) | data_bytes[tcp_off + 1]
            dst_port = (data_bytes[tcp_off + 2] << 8) | data_bytes[tcp_off + 3]
            seq = (data_bytes[tcp_off + 4] << 24) | (data_bytes[tcp_off + 5] << 16) | \
                  (data_bytes[tcp_off + 6] << 8) | data_bytes[tcp_off + 7]
            ack = (data_bytes[tcp_off + 8] << 24) | (data_bytes[tcp_off + 9] << 16) | \
                  (data_bytes[tcp_off + 10] << 8) | data_bytes[tcp_off + 11]
            data_off = (data_bytes[tcp_off + 12] >> 4) & 0xF
            flags = data_bytes[tcp_off + 13]
            window = (data_bytes[tcp_off + 14] << 8) | data_bytes[tcp_off + 15]
            tcp_cksum = (data_bytes[tcp_off + 16] << 8) | data_bytes[tcp_off + 17]

            print(f"  TCP SrcPort={src_port}, DstPort={dst_port}")
            print(f"  TCP SEQ=0x{seq:08x}, ACK=0x{ack:08x}")
            print(f"  TCP DataOffset={data_off}, Flags=0x{flags:02x}", end="")
            flag_names = []
            if flags & 0x01: flag_names.append("FIN")
            if flags & 0x02: flag_names.append("SYN")
            if flags & 0x04: flag_names.append("RST")
            if flags & 0x08: flag_names.append("PSH")
            if flags & 0x10: flag_names.append("ACK")
            print(f" ({'|'.join(flag_names)})")
            print(f"  TCP Window={window}, Checksum=0x{tcp_cksum:04x}")

            # 验证关键字段
            if src_port != 80 and dst_port != 80:
                print(f"  ⚠ Neither port is 80 (HTTP) — Src={src_port}, Dst={dst_port}")
            if flags & 0x12 == 0x12:
                print(f"  ✓ TCP SYN+ACK confirmed!")
            elif flags & 0x02:
                print(f"  → TCP SYN (connection request)")
            elif flags & 0x10:
                print(f"  → TCP ACK")

    # 检查最小帧长
    if len(data_bytes) < 64:
        print(f"  ⚠ Frame size {len(data_bytes)} < 64 (min Ethernet frame)")
        print(f"     Padding needed: {64 - len(data_bytes)} bytes")

    return issues


def main():
    input_file = sys.argv[1] if len(sys.argv) > 1 else "ila_dump.txt"

    if not os.path.exists(input_file):
        print(f"ERROR: {input_file} not found")
        sys.exit(1)

    print(f"=== MAC TX Timing Analysis ===")
    print(f"File: {input_file}")
    print(f"Sample period: {SAMPLE_PERIOD_NS} ns (50 MHz)")
    print()

    samples = parse_dump(input_file)
    print(f"Total samples: {len(samples)}")
    print(f"Time window: {len(samples) * SAMPLE_PERIOD_NS / 1000:.1f} µs")
    print()

    # ── 寻找 MAC TX 包 ──
    mac_tx_sop_edges = find_pulses(samples, "mac_tx_sop")
    mac_rx_sop_edges = find_pulses(samples, "mac_rx_sop")

    print(f"MAC RX packets (SOP edges): {len(mac_rx_sop_edges)}")
    print(f"MAC TX packets (SOP edges): {len(mac_tx_sop_edges)}")
    print()

    # ── 分析每个 TX 包 ──
    for pkt_idx, sop in enumerate(mac_tx_sop_edges):
        print(f"{'='*60}")
        print(f"MAC TX Packet #{pkt_idx + 1} @ sample {sop} (t={sop * SAMPLE_PERIOD_NS / 1000:.2f} µs)")
        print(f"{'='*60}")

        result = analyze_mac_tx_packet(samples, sop)

        # 基本信息
        print(f"  SOP: sample {result['sop_sample']}")
        if result['eop_sample'] is not None:
            print(f"  EOP: sample {result['eop_sample']} "
                  f"(duration: {result['eop_sample'] - result['sop_sample']} samples = "
                  f"{(result['eop_sample'] - result['sop_sample']) * SAMPLE_PERIOD_NS} ns)")
        print(f"  Data bytes: {len(result['data_bytes'])}")
        print(f"  GMII delay: {result['gmii_delay']} cycles ({result['gmii_delay'] * SAMPLE_PERIOD_NS} ns)"
              if result['gmii_delay'] else "  GMII delay: NOT FOUND")

        # 数据内容 (hex dump)
        if result['data_bytes']:
            print(f"\n  --- MAC TX Data ({len(result['data_bytes'])} bytes) ---")
            for row_start in range(0, len(result['data_bytes']), 16):
                chunk = result['data_bytes'][row_start:row_start + 16]
                hex_str = ' '.join(f'{b:02x}' for b in chunk)
                ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
                print(f"  {row_start:04x}: {hex_str:<48s} {ascii_str}")

        # 验证包内容
        if result['data_bytes']:
            print(f"\n  --- Packet Content Verification ---")
            issues = verify_packet_content(result['data_bytes'])
            for issue in issues:
                print(f"  ✗ {issue}")

        # GMII TX 字节对比
        if result['gmii_delay'] and result['data_bytes']:
            print(f"\n  --- GMII TX vs MAC TX Data Match ---")
            match_ok = True
            for bi, mac_byte in enumerate(result['data_bytes']):
                gidx = sop + result['gmii_delay'] + bi
                if gidx < len(samples):
                    gmii_byte = extract(samples[gidx], "gmii_txd")
                    if gmii_byte != mac_byte:
                        print(f"  ✗ Byte[{bi}]: MAC=0x{mac_byte:02x} GMII=0x{gmii_byte:02x} (MISMATCH)")
                        match_ok = False
                        if bi > 10:  # 只显示前几个不匹配
                            print(f"  ... (stopping mismatch report after 10 errors)")
                            break
            if match_ok:
                print(f"  ✓ All {len(result['data_bytes'])} bytes match between MAC TX and GMII TX!")

        # 错误报告
        if result['errors']:
            print(f"\n  --- ⚠ Timing Errors ---")
            for err in result['errors']:
                print(f"  ✗ {err}")
        else:
            print(f"\n  ✓ No timing errors detected")

        if result['has_error']:
            print(f"  ⚠ mac_tx_err asserted during this packet!")

        print()

    # ── 帧间隙分析 ──
    if len(mac_tx_sop_edges) >= 2:
        print(f"{'='*60}")
        print(f"Inter-Frame Gap (IFG) Analysis")
        print(f"{'='*60}")
        for i in range(len(mac_tx_sop_edges) - 1):
            gap = mac_tx_sop_edges[i + 1] - mac_tx_sop_edges[i]
            gap_ns = gap * SAMPLE_PERIOD_NS
            print(f"  Gap {i}→{i + 1}: {gap} samples = {gap_ns} ns ({gap_ns / 1000:.1f} µs)")
        # 以太网最小 IFG = 96 bit times = 960 ns @ 100Mbps
        print(f"  Min Ethernet IFG: 960 ns (12 bytes @ 100 Mbps)")

    # ── 关键时序总结 ──
    print(f"\n{'='*60}")
    print(f"Timing Summary")
    print(f"{'='*60}")

    # CPU FIFO 活动
    pop_edges = find_pulses(samples, "cpu_rd_rpkt_pop_ind")
    push_edges = find_pulses(samples, "cpu_wr_wpkt_push_ind")
    wen_edges = find_pulses(samples, "cpu_wr_wen_ind")

    print(f"  RX pop pulses: {len(pop_edges)}")
    for i, e in enumerate(pop_edges):
        print(f"    pop#{i} @ sample {e} (t={e * 20 / 1000:.1f} µs)")
    print(f"  TX push pulses: {len(push_edges)}")
    for i, e in enumerate(push_edges):
        print(f"    push#{i} @ sample {e} (t={e * 20 / 1000:.1f} µs)")
    print(f"  TX wen pulses: {len(wen_edges)}")

    if pop_edges and push_edges:
        # 固件处理延时: POP → PUSH
        fw_latency = push_edges[0] - pop_edges[0]
        print(f"\n  Firmware latency (POP→PUSH): {fw_latency} samples = {fw_latency * 20 / 1000:.1f} µs")

    if push_edges and mac_tx_sop_edges:
        # TX push → MAC TX SOP 延时
        tx_push_to_sop = mac_tx_sop_edges[0] - push_edges[0]
        print(f"  TX PUSH→MAC_TX_SOP delay: {tx_push_to_sop} samples = {tx_push_to_sop * 20} ns")

    # 最终结论
    print(f"\n{'='*60}")
    all_ok = True
    for pkt_idx, sop in enumerate(mac_tx_sop_edges):
        result = analyze_mac_tx_packet(samples, sop)
        if result['errors']:
            all_ok = False
            break

    if mac_tx_sop_edges and all_ok:
        print(f"✓ MAC TX Timing VERIFIED — {len(mac_tx_sop_edges)} packet(s), no timing errors")
    elif not mac_tx_sop_edges:
        print(f"✗ NO MAC TX packets detected!")
    else:
        print(f"✗ MAC TX Timing FAILED — see errors above")

    print()


if __name__ == "__main__":
    main()
