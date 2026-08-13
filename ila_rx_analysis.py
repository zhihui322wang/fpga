#!/usr/bin/env python3
"""
ILA RX 通路分析 — 抓一帧 ARP 请求进来, 看 cpu_rd_empty 是否在帧结束后变 0

触发: mac_rx_sop (probe4, bit18)
关键信号时序: mac_rx_sop/en/eop → cpu_rd_empty → cpu_rd_rpkt_pop_ind
用法:
  1. python3 ila_rx_analysis.py     # arm + 等触发 (60s), 期间请 ping
  2. 脚本触发后自动读波形并解析
"""
import sys, time
sys.path.insert(0, "/home/zhihuiw/fpga_work/fpga_ila_local/host")
from fpga_ila import Device, SerialTransport, protocol as P
from fpga_ila.capture import decode_samples

PORT = "/dev/ttyACM0"; BAUD = 921600; CORE = 0
ADDR_TRIG_MODE=0x0020; ADDR_TRIG_VALUE=0x0024; ADDR_TRIG_MASK=0x0028
ADDR_PRETRIG=0x0014; ADDR_POSTTRIG=0x0018

# probe 位偏移 (webserver_cpu_top.v 32-probe 拼接顺序)
PROBE_WIDTHS = [1,8,1,8, 1,1,8,1, 1,1,8,1, 1,1,1,32, 32,1,32,1, 1,1,1, 1,1,4,8, 8,8,8, 1,1]
def bit_lo(idx):
    return sum(PROBE_WIDTHS[:idx])

def main():
    t = SerialTransport(PORT, BAUD); dev = Device(t)
    try:
        idc = dev.ping()
        print(f"[1] PING OK idcode={idc:#x}")
    except Exception as e:
        print(f"[1] PING FAILED: {e}"); return 1

    # 触发 mac_rx_sop (probe4)
    bi = bit_lo(4); w = bi//32; b = bi%32
    dev.reg_write(CORE, ADDR_TRIG_MODE, 0x01)
    for k in range(6):
        dev.reg_write(CORE, ADDR_TRIG_VALUE+k, 0); dev.reg_write(CORE, ADDR_TRIG_MASK+k, 0)
    dev.reg_write(CORE, ADDR_TRIG_VALUE+w, 1<<b); dev.reg_write(CORE, ADDR_TRIG_MASK+w, 1<<b)
    print(f"[2] 触发 mac_rx_sop: bit{bi} (word{w} bit{b})")

    dev.reg_write(CORE, ADDR_PRETRIG, 256); dev.reg_write(CORE, ADDR_POSTTRIG, 1791)
    dev.arm(CORE); time.sleep(0.1)
    print(f"[3] ARM 完成, 请立即 ping 169.254.1.1 (等 60s)...")

    done=False; st=0
    for i in range(600):
        time.sleep(0.1); st=dev.get_status(CORE); done=(st>>2)&1
        if done: break
    if not done:
        print(f"[4] 超时未触发 status={st:#x} → 无 RX 帧进来"); dev.t.close(); return 0
    print(f"[4] 已触发 status={st:#x}")

    # 读波形
    cfg = dev.get_core_cfg(CORE)
    raw = bytearray()
    chunk = max(1, 512 // cfg.bytes_per_sample)
    a=0
    while a < cfg.data_depth:
        n=min(chunk, cfg.data_depth-a); raw += dev.read_buf(CORE,a,n); a+=n
    samples = decode_samples(bytes(raw), cfg.total_width)
    print(f"[5] 读到 {len(samples)} 样本 (total_width={cfg.total_width})")

    # 解析关键信号
    def sig(idx, wd):
        m=(1<<wd)-1; bl=bit_lo(idx); return [(s>>bl)&m for s in samples]

    sop = sig(4,1); en = sig(5,1); eop = sig(7,1)
    rd_empty = sig(19,1); rd_pop = sig(21,1); rd_ren = sig(24,1)
    rxc_cnt = sig(27,8); drop = sig(29,8); mfull = sig(30,1)
    tx_sop = sig(8,1); tx_en = sig(9,1)

    # 找到 sop 触发点 (pretrig=256 处)
    pretrig=256
    # 打印 sop=1 附近 + 之后 120 拍的时序
    print("\n=== 关键时序 (相对 sop 触发点, pretrig=256) ===")
    print(f"{'t':>4} {'sop':>3} {'en':>3} {'eop':>3} {'rd_empty':>8} {'rd_pop':>6} {'rd_ren':>6} {'rxcnt':>5} {'drop':>4} {'mfull':>5} {'tx_sop':>6} {'tx_en':>5}")
    for t in range(-8, 121):
        idx = pretrig + t
        if 0 <= idx < len(samples):
            print(f"{t:>4} {sop[idx]:>3} {en[idx]:>3} {eop[idx]:>3} {rd_empty[idx]:>8} {rd_pop[idx]:>6} {rd_ren[idx]:>6} {rxc_cnt[idx]:>5} {drop[idx]:>4} {mfull[idx]:>5} {tx_sop[idx]:>6} {tx_en[idx]:>5}")

    # 关键判断
    print("\n=== 结论 ===")
    post = [i for i in range(pretrig+2, min(pretrig+120, len(samples)))]
    empty_after = any(rd_empty[i]==0 for i in post)
    print(f"rx_correct_pkt_cnt 在触发点值 = {rxc_cnt[pretrig]}")
    print(f"触发后 120 拍内 rd_empty 变 0 (有包到读侧)? {empty_after}")
    if not empty_after:
        print("  → cpu_rd_empty 一直 1: 包没进 package_fifo 读侧 (wpkt_push/CDC 问题)")
    else:
        first_nonempty = next(i for i in post if rd_empty[i]==0)
        print(f"  → 触发后第 {first_nonempty-pretrig} 拍 rd_empty 变 0: 包到了读侧")
        print(f"  → 若 rd_pop 无脉冲, 则是 CPU 没读 (固件 LCPU_RD_EMPTY 判空逻辑)")

    dev.t.close(); return 0

if __name__ == "__main__":
    sys.exit(main())
