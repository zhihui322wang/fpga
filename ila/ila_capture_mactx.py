#!/usr/bin/env python3
"""
ILA 触发配置 — 二分定位「CPU 到底发没发 ARP 回复」

触发信号: mac_tx_sop (probe8, 位29)  —— CPU 发 TX 包的第一拍
  - 触发成功 (triggered=1) → CPU 确实发了 ARP 回复 → 问题在 TX 后段 (gmii2mac/rgmii/PHY)
  - 超时 (triggered=0)     → CPU 没发 ARP 回复    → 问题在 RX (CPU没收到) 或 arp_reply 检查

用法:
  1. 确认 ILA GUI 已关闭 (释放 /dev/ttyACM0)
  2. python3 ila_capture_mactx.py            # 配置 + arm + 等待
  3. 另一终端: ping -c 4 169.254.1.1         # 产生 ARP 流量
  4. 看本脚本输出 triggered 状态

可选: python3 ila_capture_mactx.py wr_push    # 改用 cpu_wr_wpkt_push_ind (probe22) 触发
"""
import sys
import time
sys.path.insert(0, "/home/zhihuiw/fpga_work/fpga_ila_local/host")
from fpga_ila import Device, SerialTransport, protocol as P

PORT = "/dev/ttyACM0"
BAUD = 921600
CORE = 0

# 寄存器地址 (FCAPZ/ila_ela, 已验证有效)
ADDR_TRIG_MODE  = 0x0020
ADDR_TRIG_VALUE = 0x0024   # 触发值 (多字, base)
ADDR_TRIG_MASK  = 0x0028   # 触发掩码 (多字, base)
ADDR_PRETRIG    = 0x0014
ADDR_POSTTRIG   = 0x0018
ADDR_CTRL       = 0x0004
ADDR_STATUS     = 0x0008

# 探针位偏移 (32 probe 拼接顺序, 见 webserver_cpu_top.v)
# probe0 gmii_rx_dv(1) probe1 gmii_rxd(8) probe2 gmii_tx_en(1) probe3 gmii_txd(8)
# probe4 mac_rx_sop(1) probe5 mac_rx_en(1) probe6 mac_rx_data(8) probe7 mac_rx_eop(1)
# probe8 mac_tx_sop(1) probe9 mac_tx_en(1) probe10 mac_tx_data(8) probe11 mac_tx_eop(1)
# probe12 mac_tx_err(1) probe13 bus_req(1) probe14 bus_rhwl(1) probe15 bus_address(32)
# probe16 bus_rdata(32) probe17 bus_ack(1) probe18 bus_wdata(32) probe19 cpu_rd_empty(1)
# probe20 cpu_wr_full(1) probe21 cpu_rd_rpkt_pop_ind(1) probe22 cpu_wr_wpkt_push_ind(1)
# probe23 cpu_wr_wen_ind(1) probe24 cpu_rd_ren(1) probe25 led(4) probe26 rx_afifo_full_cnt(8)
# probe27 rx_correct_pkt_cnt(8) probe28 rx_crc_err_pkt_cnt(8) probe29 recv_pkt_drop_cnt(8)
# probe30 mac_in_full(1) probe31 gmii_rx_er(1)

def bit_pos(probe_widths, probe_idx):
    """返回 probe_idx 的起始位 (跨 word 用全局位号)"""
    pos = 0
    for i in range(probe_idx):
        pos += probe_widths[i]
    return pos

PROBE_WIDTHS = [1,8,1,8, 1,1,8,1, 1,1,8,1, 1,1,1,32, 32,1,32,1, 1,1,1, 1,1,4,8, 8,8,8, 1,1]

def set_trigger(dev, probe_idx, mode="value"):
    """设置触发: 监测 probe_idx 信号"""
    global_bit = bit_pos(PROBE_WIDTHS, probe_idx)
    word_idx  = global_bit // 32
    bit_in_word = global_bit % 32
    val = 1 << bit_in_word

    # 触发模式: bit0=value_match, bit1=edge
    trig_mode = 0x01 if mode == "value" else 0x03
    dev.reg_write(CORE, ADDR_TRIG_MODE, trig_mode)

    # 清空 6 个 word
    for w in range(6):
        dev.reg_write(CORE, ADDR_TRIG_VALUE + w, 0)
        dev.reg_write(CORE, ADDR_TRIG_MASK  + w, 0)

    dev.reg_write(CORE, ADDR_TRIG_VALUE + word_idx, val)
    dev.reg_write(CORE, ADDR_TRIG_MASK  + word_idx, val)

    return global_bit, word_idx, bit_in_word, val

def main():
    probe_sel = sys.argv[1] if len(sys.argv) > 1 else "mactx"
    if probe_sel == "wr_push":
        probe_idx, label = 22, "cpu_wr_wpkt_push_ind"
    else:
        probe_idx, label = 8, "mac_tx_sop"

    print("=" * 60)
    print(f"ILA 触发配置 — {label} (probe{probe_idx}) 触发")
    print(f"  端口: {PORT} @ {BAUD}")
    print("=" * 60)

    t = SerialTransport(PORT, BAUD)
    dev = Device(t)

    # Step 1: PING
    try:
        idcode = dev.ping()
        print(f"[1] PING OK — IDCODE {idcode:#010x}")
    except Exception as e:
        print(f"[1] PING FAILED: {e}")
        print("    请确认 ILA GUI 已关闭, FPGA 已烧录 (UART 归 ILA)")
        return 1

    # Step 2: 配置触发
    gbit, widx, bw, val = set_trigger(dev, probe_idx)
    print(f"[2] 触发 {label}: 全局位{gbit} = word{widx} bit{bw} (0x{val:08x})")
    rv = dev.reg_read(CORE, ADDR_TRIG_VALUE + widx)
    rm = dev.reg_read(CORE, ADDR_TRIG_MASK  + widx)
    print(f"    读回 TRIG_VALUE[{widx}]={rv:#010x} TRIG_MASK[{widx}]={rm:#010x}")

    # Step 3: 采集窗口
    PRETRIG, POSTTRIG = 256, 1791   # 触发后 35.8us, 足够看完整 TX 回复
    dev.reg_write(CORE, ADDR_PRETRIG,  PRETRIG)
    dev.reg_write(CORE, ADDR_POSTTRIG, POSTTRIG)
    print(f"[3] PRETRIG={PRETRIG} POSTTRIG={POSTTRIG} (总{PRETRIG+POSTTRIG+1})")

    # Step 4: ARM
    dev.arm(CORE)
    time.sleep(0.1)
    st = dev.get_status(CORE)
    print(f"[4] ARM 后 status={st:#x} (armed={st&1} trig={(st>>1)&1} done={(st>>2)&1})")

    # Step 5: 等待
    print(f"\n[5] 请另开终端: ping -c 4 169.254.1.1")
    print(f"    等待触发 (timeout=60s)...")
    done = False
    st = 0
    for i in range(600):
        time.sleep(0.1)
        st = dev.get_status(CORE)
        done = (st >> 2) & 1
        trig = (st >> 1) & 1
        if done:
            print(f"\n    ✓ 已触发并采集完成 (status={st:#x}, trig={trig})")
            break
        if i % 100 == 99:
            print(f"    等待中 {i*0.1:.0f}s (status={st:#x})")

    if not done:
        print(f"\n    ⚠ 超时未触发 (status={st:#x})")
        print(f"      → CPU 未发 {label} 信号")

    # 结论
    print("\n" + "=" * 60)
    if done:
        print(f"✓ 触发成功: {label}=1 出现过")
        if probe_idx == 8:
            print("  → CPU 发了 ARP 回复, 问题在 TX 后段 (gmii2mac/rgmii/PHY)")
        else:
            print("  → CPU 推了 TX 包, 问题在 TX FIFO→mac_tx 之间")
    else:
        print(f"✗ 未触发: {label} 从未为 1")
        if probe_idx == 8:
            print("  → CPU 未发 ARP 回复 (RX 没收到 / arp_reply 检查失败)")
        else:
            print("  → CPU 未推 TX 包 (RX 没收到)")
    print("=" * 60)

    dev.t.close()
    return 0

if __name__ == "__main__":
    sys.exit(main())
