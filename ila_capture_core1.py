#!/usr/bin/env python3
"""
ILA 核1 (125MHz) 抓波 — GMII/MAC RX 全链路
触发: gmii_rx_dv (probe0, bit0) = 1, 值匹配
流量: ping 169.254.1.1 产生

用法:
  1. 确认 ILA GUI 已关闭 (释放串口 /dev/ttyACM1)
  2. python3 ila_capture_core1.py
  3. 脚本自动 arm 核1 → 后台 ping 触发 → 回读 → 导出 VCD/CSV
"""
import sys, time, subprocess, threading

# 用当前 fpga_ila host (ip_copy) 的完整 API
sys.path.insert(0, "/home/zhihuiw/fpga_work/ip_copy/host")
from fpga_ila import Device, SerialTransport
from fpga_ila.capture import Capture, load_signals
from fpga_ila import exporters

PORT = "/dev/ttyACM1"
BAUD = 921600
CORE = 1
SIGNALS = "/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/signals.json"
OUT_VCD = "/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/core1_capture.vcd"
OUT_CSV = "/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/core1_capture.csv"

ADDR_TRIG_MODE  = 0x0020
ADDR_TRIG_VALUE = 0x0024
ADDR_TRIG_MASK  = 0x0028
ADDR_PRETRIG    = 0x0014
ADDR_POSTTRIG   = 0x0018

def main():
    print("=" * 64)
    print("ILA 核1 (125MHz) 抓波 — GMII/MAC RX 全链路")
    print(f"  端口 {PORT} @ {BAUD} | 核1 | 触发 gmii_rx_dv=1")
    print("=" * 64)

    t = SerialTransport(PORT, BAUD)
    dev = Device(t)

    # ---- ping hub ----
    idcode = dev.ping()
    print(f"[1] PING OK  IDCODE={idcode:#010x}")

    # ---- 读核1配置，验证是 41bit / 2048 深 ----
    cfg = dev.get_core_cfg(CORE)
    print(f"[2] 核{CORE} 配置: sample_w={cfg.total_width} depth={cfg.data_depth} "
          f"segments={cfg.max_windows}")
    if cfg.total_width != 41:
        print(f"  ⚠ 期望 41bit (核1), 实际 {cfg.total_width}bit — 可能核号不对")
        return 1

    # ---- 触发配置: gmii_rx_dv (bit0) = 1 ----
    print("[3] 触发: gmii_rx_dv=1 (值匹配)")
    dev.reg_write(CORE, ADDR_TRIG_MODE, 0x1)
    for w in range(2):  # 41bit = 2 字
        dev.reg_write(CORE, ADDR_TRIG_VALUE + w, 0x0)
        dev.reg_write(CORE, ADDR_TRIG_MASK  + w, 0x0)
    dev.reg_write(CORE, ADDR_TRIG_VALUE + 0, 0x1)  # bit0 = gmii_rx_dv
    dev.reg_write(CORE, ADDR_TRIG_MASK  + 0, 0x1)  # 只比较 bit0

    # ---- 采集窗口: pre=512 post=1535 (2048 总) ----
    PRETRIG, POSTTRIG = 512, 1535
    dev.reg_write(CORE, ADDR_PRETRIG,  PRETRIG)
    dev.reg_write(CORE, ADDR_POSTTRIG, POSTTRIG)
    print(f"[4] 窗口 pre={PRETRIG} post={POSTTRIG}")

    # ---- arm ----
    dev.arm(CORE)
    time.sleep(0.2)
    st = dev.get_status(CORE)
    print(f"[5] ARM 状态: armed={bool(st&1)} trig={bool(st&2)} done={bool(st&4)}")

    # ---- 后台 ping 触发 ----
    print("[6] 后台 ping 169.254.1.1 触发...")
    ping_done = threading.Event()
    def do_ping():
        subprocess.run(["ping", "-c", "6", "-i", "0.2", "169.254.1.1"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ping_done.set()
    threading.Thread(target=do_ping, daemon=True).start()

    # ---- 等 done ----
    dev.wait_full(CORE, timeout=12)

    # ---- 回读 ----
    print("[7] 回读样本...")
    samples = dev.read_all_samples(CORE, cfg)
    print(f"  读到 {len(samples)} 个样本")

    # ---- 组装 Capture 并导出 ----
    sigs = load_signals(SIGNALS)
    cs = sigs[CORE]
    cap = Capture(cfg=cfg, phys_samples=samples, win_starts=[0],
                  windows_num=1, capture_len=len(samples))
    exporters.to_vcd(cap, cs, OUT_VCD)
    exporters.to_csv(cap, cs, OUT_CSV)
    print(f"[8] 导出:")
    print(f"    VCD: {OUT_VCD}")
    print(f"    CSV: {OUT_CSV}")

    # ---- 解码摘要: 打印 RX 数据帧的 SOP/EOP 及前若干字节 ----
    print("\n[9] 解码摘要 (gmii_rx_dv / mac_rx_sop / mac_rx_eop / gmii_rxd):")
    dv   = cap.signal_by_probe(next(p for p in cs.probes if p.name=="gmii_rx_dv"))
    sop  = cap.signal_by_probe(next(p for p in cs.probes if p.name=="mac_rx_sop"))
    eop  = cap.signal_by_probe(next(p for p in cs.probes if p.name=="mac_rx_eop"))
    rxd  = cap.signal_by_probe(next(p for p in cs.probes if p.name=="gmii_rxd"))
    rden = cap.signal_by_probe(next(p for p in cs.probes if p.name=="mac_rx_en"))
    rdata= cap.signal_by_probe(next(p for p in cs.probes if p.name=="mac_rx_data"))
    # 找第一个 dv=1 的位置 (触发点)
    trig = next((i for i,v in enumerate(dv) if v), None)
    print(f"  触发点 (首个 gmii_rx_dv=1) @ sample {trig}")
    # 打印触发点前后 RX 字节流 (从 mac_rx_en 抓数据)
    if trig is not None:
        print(f"  gmii_rxd 前 16 字节 @触发点: "
              + " ".join(f"{rxd[(trig+k) % len(rxd)]:02x}" for k in range(16)))
        # mac_rx_data 有效 (en=1) 的前 N 字节
        valid = [(i, rdata[i]) for i in range(trig, min(trig+200, len(rdata))) if rden[i]]
        print(f"  mac_rx_data 有效字节 (en=1, 前 24): "
              + " ".join(f"{d:02x}" for _,d in valid[:24]))
        print(f"  帧内 SOP 采样点: {[i for i,v in enumerate(sop) if v][:5]}")
        print(f"  帧内 EOP 采样点: {[i for i,v in enumerate(eop) if v][:5]}")

    dev.t.close()
    print("\n✅ 完成。用 GTKWave 打开 core1_capture.vcd 或重开 GUI 查看。")
    return 0

if __name__ == "__main__":
    sys.exit(main())
