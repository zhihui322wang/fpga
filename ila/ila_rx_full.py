#!/usr/bin/env python3
"""
ILA RX 全链路分析 (可靠触发版)
触发: gmii_rx_dv (probe0, bit0) —— 帧期间持续拉高, 50MHz 采样必然捕获
  (mac_rx_sop 是 clk_125m 域 8ns 单拍脉冲, 50MHz 采样会漏, 故不可靠, 弃用)

一个窗口内看完整链路:
  gmii_rx_dv -> mac_rx_sop/en/eop -> cpu_rd_empty(包到读侧) -> mac_tx_sop(TX回复)
用法: python3 ila_rx_full.py   (arm 后脚本会自己 ping 169.254.1.1)
"""
import sys, time, subprocess
sys.path.insert(0, "/home/zhihuiw/fpga_work/fpga_ila_local/host")
from fpga_ila import Device, SerialTransport, protocol as P
from fpga_ila.capture import decode_samples

PORT = "/dev/ttyACM0"; BAUD = 921600; CORE = 0
ADDR_TRIG_MODE=0x0020; ADDR_TRIG_VALUE=0x0024; ADDR_TRIG_MASK=0x0028
ADDR_PRETRIG=0x0014; ADDR_POSTTRIG=0x0018

PROBE_WIDTHS = [1,8,1,8, 1,1,8,1, 1,1,8,1, 1,1,1,32, 32,1,32,1, 1,1,1, 1,1,4,8, 8,8,8, 1,1]
def bit_lo(idx):
    return sum(PROBE_WIDTHS[:idx])

def main():
    t = SerialTransport(PORT, BAUD); dev = Device(t)
    try:
        idc = dev.ping(); print(f"[1] PING OK idcode={idc:#x}")
    except Exception as e:
        print(f"[1] PING FAILED: {e}"); return 1

    # 触发 gmii_rx_dv (probe0, bit0)
    bi = bit_lo(0); w = bi//32; b = bi%32
    dev.reg_write(CORE, ADDR_TRIG_MODE, 0x01)
    for k in range(6):
        dev.reg_write(CORE, ADDR_TRIG_VALUE+k, 0); dev.reg_write(CORE, ADDR_TRIG_MASK+k, 0)
    dev.reg_write(CORE, ADDR_TRIG_VALUE+w, 1<<b); dev.reg_write(CORE, ADDR_TRIG_MASK+w, 1<<b)
    print(f"[2] 触发 gmii_rx_dv: bit{bi}")

    # 触发后尽量多看 (ARP回复全程), pretrigger 小
    dev.reg_write(CORE, ADDR_PRETRIG, 64); dev.reg_write(CORE, ADDR_POSTTRIG, 1983)
    dev.arm(CORE); time.sleep(0.1)
    print(f"[3] ARM 完成, 开始自己 ping 169.254.1.1 ...")

    # 自己 ping (后台), 产生 ARP 请求
    pingp = subprocess.Popen(["ping","-c","8","-W","1","169.254.1.1"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    done=False; st=0
    for i in range(300):
        time.sleep(0.1); st=dev.get_status(CORE); done=(st>>2)&1
        if done: break
    pingp.terminate()
    if not done:
        print(f"[4] 超时未触发 status={st:#x} (armed={st&1} trig={(st>>1)&1}) → gmii_rx_dv 从未为 1"); dev.t.close(); return 0
    print(f"[4] 已触发 status={st:#x}")

    cfg = dev.get_core_cfg(CORE)
    raw = bytearray(); chunk = max(1, 512 // cfg.bytes_per_sample); a=0
    while a < cfg.data_depth:
        n=min(chunk, cfg.data_depth-a); raw += dev.read_buf(CORE,a,n); a+=n
    samples = decode_samples(bytes(raw), cfg.total_width)
    print(f"[5] 读到 {len(samples)} 样本 (total_width={cfg.total_width})")

    def sig(idx, wd):
        m=(1<<wd)-1; bl=bit_lo(idx); return [(s>>bl)&m for s in samples]

    dv    = sig(0,1); rxd  = sig(1,8)
    m_sop = sig(4,1); m_en = sig(5,1); m_data = sig(6,8); m_eop = sig(7,1)
    t_sop = sig(8,1); t_en = sig(9,1); t_data = sig(10,8); t_eop = sig(11,1)
    rd_empty = sig(19,1); rd_pop = sig(21,1); rd_ren = sig(24,1)
    rxc_cnt = sig(27,8); drop = sig(29,8); mfull = sig(30,1)

    pretrig = 64
    # 找 dv 首个上升沿做参考 (trigger 点在 pretrig)
    print("\n=== 全链路关键信号 (相对触发点, pretrig=64) ===")
    print(f"{'t':>4} {'dv':>3} {'m_sop':>5} {'m_en':>5} {'m_eop':>5} {'t_sop':>5} {'t_en':>5} {'rd_empty':>8} {'rd_pop':>6} {'rd_ren':>6} {'rxcnt':>5} {'drop':>4} {'mfull':>5}")
    for tt in range(-8, 200):
        idx = pretrig + tt
        if 0 <= idx < len(samples):
            print(f"{tt:>4} {dv[idx]:>3} {m_sop[idx]:>5} {m_en[idx]:>5} {m_eop[idx]:>5} {t_sop[idx]:>5} {t_en[idx]:>5} {rd_empty[idx]:>8} {rd_pop[idx]:>6} {rd_ren[idx]:>6} {rxc_cnt[idx]:>5} {drop[idx]:>4} {mfull[idx]:>5}")

    # 汇总
    print("\n=== 汇总 ===")
    n = len(samples)
    dv_any = any(dv[i] for i in range(n))
    msop_any = any(m_sop[i] for i in range(n))
    meop_any = any(m_eop[i] for i in range(n))
    tsop_any = any(t_sop[i] for i in range(n))
    empty_low = any(rd_empty[i]==0 for i in range(n))
    print(f"gmii_rx_dv 出现过:        {dv_any}")
    print(f"mac_rx_sop 出现过:        {msop_any}  (125MHz单拍, 可能漏采, 仅供参考)")
    print(f"mac_rx_eop 出现过:        {meop_any}")
    print(f"mac_tx_sop 出现过:        {tsop_any}  (TX回复第一拍)")
    print(f"cpu_rd_empty 变 0 过:     {empty_low}  (包到读侧)")
    print(f"rx_correct_pkt_cnt 末值:  {rxc_cnt[-1]}")
    print(f"recv_pkt_drop_cnt 末值:   {drop[-1]}")
    print(f"mac_in_full 末值:         {mfull[-1]}")

    dev.t.close(); return 0

if __name__ == "__main__":
    sys.exit(main())
