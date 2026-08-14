#!/usr/bin/env python3
"""
ILA 核0 (50MHz) 抓波 — CPU 总线信号 (clk_50m 域)
触发: cpu_wr_wen_ind (bit144) = 1, 值匹配 (CPU 写 TX 包 FIFO 单拍脉冲, 仅发送回复包时发生)
流量: ping 169.254.1.1 产生 CPU 总线活动 (读 RX 包 + 写 TX 包)

用法:
  1. 确认 ILA GUI 已关闭 (释放串口 /dev/ttyACM1)
  2. python3 ila_capture_core0.py
"""
import sys, time, subprocess, threading

sys.path.insert(0, "/home/zhihuiw/fpga_work/ip_copy/host")
from fpga_ila import Device, SerialTransport
from fpga_ila.capture import Capture, load_signals
from fpga_ila import exporters

PORT = "/dev/ttyACM1"
BAUD = 921600
CORE = 0
SIGNALS = "/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/signals.json"
OUT_VCD = "/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/core0_capture.vcd"
OUT_CSV = "/home/zhihuiw/fpga_work/Prj/RiscV_WebSoC_3/core0_capture.csv"

ADDR_TRIG_MODE  = 0x0020
ADDR_PRETRIG    = 0x0014
ADDR_POSTTRIG   = 0x0018

def main():
    print("=" * 64)
    print("ILA 核0 (50MHz) 抓波 — CPU 总线信号")
    print(f"  端口 {PORT} @ {BAUD} | 核0 | 触发 bus_req=1")
    print("=" * 64)

    t = SerialTransport(PORT, BAUD)
    dev = Device(t)

    idcode = dev.ping()
    print(f"[1] PING OK  IDCODE={idcode:#010x}")

    cfg = dev.get_core_cfg(CORE)
    print(f"[2] 核0 配置: sample_w={cfg.total_width} depth={cfg.data_depth} "
          f"segments={cfg.max_windows}")
    if cfg.total_width != 184:
        print(f"  ⚠ 期望 184bit (核0), 实际 {cfg.total_width}bit")
        return 1

    # ---- 触发: cpu_wr_wen_ind (bit144) = 1 ----
    sigs = load_signals(SIGNALS)
    cs = sigs[CORE]
    trig_bit = next(p for p in cs.probes if p.name == "cpu_wr_wen_ind").bit_lo
    print(f"[3] 触发 cpu_wr_wen_ind=1 (bit_lo={trig_bit})")
    dev.reg_write(CORE, ADDR_TRIG_MODE, 0x1)
    dev.set_trigger(CORE, value=1 << trig_bit, mask=1 << trig_bit,
                    total_width=cfg.total_width)

    # ---- 窗口 ----
    PRETRIG, POSTTRIG = 512, 1535
    dev.reg_write(CORE, ADDR_PRETRIG,  PRETRIG)
    dev.reg_write(CORE, ADDR_POSTTRIG, POSTTRIG)
    print(f"[4] 窗口 pre={PRETRIG} post={POSTTRIG}")

    # ---- arm ----
    dev.arm(CORE)
    time.sleep(0.2)
    st = dev.get_status(CORE)
    print(f"[5] ARM 状态: armed={bool(st&1)} trig={bool(st&2)} done={bool(st&4)}")

    # ---- 后台 ping ----
    print("[6] 后台 ping 169.254.1.1 触发...")
    def do_ping():
        subprocess.run(["ping", "-c", "6", "-i", "0.2", "169.254.1.1"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    threading.Thread(target=do_ping, daemon=True).start()

    dev.wait_full(CORE, timeout=12)

    print("[7] 回读样本...")
    samples = dev.read_all_samples(CORE, cfg)
    print(f"  读到 {len(samples)} 个样本")

    # ---- 组装 Capture + 导出 ----
    cap = Capture(cfg=cfg, phys_samples=samples, win_starts=[0],
                  windows_num=1, capture_len=len(samples))
    exporters.to_vcd(cap, cs, OUT_VCD)
    exporters.to_csv(cap, cs, OUT_CSV)
    print(f"[8] 导出 VCD: {OUT_VCD} | CSV: {OUT_CSV}")

    # ---- 解码 CPU 总线摘要 ----
    print("\n[9] CPU 总线活动摘要 (触发点附近):")
    req   = cap.signal_by_probe(next(p for p in cs.probes if p.name=="bus_req"))
    rhwl  = cap.signal_by_probe(next(p for p in cs.probes if p.name=="bus_rhwl"))
    addr  = cap.signal_by_probe(next(p for p in cs.probes if p.name=="bus_address"))
    rdata = cap.signal_by_probe(next(p for p in cs.probes if p.name=="bus_rdata"))
    wdata = cap.signal_by_probe(next(p for p in cs.probes if p.name=="bus_wdata"))
    ack   = cap.signal_by_probe(next(p for p in cs.probes if p.name=="bus_ack"))
    wen   = cap.signal_by_probe(next(p for p in cs.probes if p.name=="cpu_wr_wen_ind"))

    trig = next((i for i,v in enumerate(wen) if v), None)
    print(f"  触发点 (首个 cpu_wr_wen_ind=1) @ sample {trig}")
    if trig is not None:
        # 打印触发点前后有总线活动的拍 (req/ack/wen 任一为 1), 压缩空闲拍
        lo = max(0, trig - 200)
        hi = min(len(req), trig + 400)
        print(f"  {'idx':>4} {'req':>3} {'rhwl':>4} {'address':>10} {'wdata':>10} {'rdata':>10} {'ack':>3} {'wen':>3}")
        for i in range(lo, hi):
            if not (req[i] or ack[i] or wen[i]):
                continue
            mark = "<-触发" if wen[i] else ""
            print(f"  {i:>4} {req[i]:>3} {rhwl[i]:>4} "
                  f"{addr[i]:>10x} {wdata[i]:>10x} {rdata[i]:>10x} {ack[i]:>3} {wen[i]:>3} {mark}")

    # 统计总线事务次数
    txns = 0
    prev = 0
    for v in req:
        if v and not prev:
            txns += 1
        prev = v
    print(f"\n  总线事务 (bus_req 上升沿) 总数: {txns}")

    dev.t.close()
    print("\n✅ 完成。用 GTKWave 打开 core0_capture.vcd 或重开 GUI 查看。")
    return 0

if __name__ == "__main__":
    sys.exit(main())
