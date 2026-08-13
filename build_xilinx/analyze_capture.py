#!/usr/bin/env python3
"""分析 ILA 采集: 触发 gmii_rx_dv, 回读并分析 RX 数据通路 (GMII→MAC→CPU FIFO)."""
import sys, time, threading, subprocess
sys.path.insert(0, "/home/zhihuiw/fpga_work/fpga_ila_local/host")
from fpga_ila import Device, SerialTransport

PORT = "/dev/ttyACM0"
BAUD = 921600
CORE = 0
IFACE = "enx9c69d37d474c"
TARGET = "169.254.1.1"

ADDR_TRIG_VALUE = 0x0024
ADDR_TRIG_MASK  = 0x0028
ADDR_PRETRIG    = 0x0014
ADDR_POSTTRIG   = 0x0018
ADDR_TRIG_MODE  = 0x0020

# 探针位偏移 (signals.json 顺序)
P = dict(
    gmii_rx_dv=(0,1), gmii_rxd=(1,8), gmii_tx_en=(9,1), gmii_txd=(10,8),
    mac_rx_sop=(18,1), mac_rx_en=(19,1), mac_rx_data=(20,8), mac_rx_eop=(28,1),
    mac_tx_sop=(29,1), mac_tx_en=(30,1), mac_tx_data=(31,8), mac_tx_eop=(39,1), mac_tx_err=(40,1),
    bus_req=(41,1), bus_rhwl=(42,1), bus_address=(43,32), bus_rdata=(75,32),
    bus_ack=(107,1), bus_wdata=(108,32),
    cpu_rd_empty=(140,1), cpu_wr_full=(141,1), cpu_rd_rpkt_pop_ind=(142,1),
    cpu_wr_wpkt_push_ind=(143,1), cpu_wr_wen_ind=(144,1), cpu_rd_ren=(145,1),
    led_o=(146,4),
    rx_afifo_full_cnt=(150,8), rx_correct_pkt_cnt=(158,8), rx_crc_err_pkt_cnt=(166,8),
    recv_pkt_drop_cnt=(174,8), mac_in_full=(182,1), gmii_rx_er=(183,1),
)

def main():
    t = SerialTransport(PORT, BAUD)
    dev = Device(t)
    idcode = dev.ping()
    print(f"PING OK: {idcode:#010x}")

    dev.disarm(CORE); time.sleep(0.05)

    # 触发: gmii_rx_dv = 1 (bit 0)
    dev.reg_write(CORE, ADDR_TRIG_MODE, 1)
    for i in range(6):   # 184bit = 6 个 32-bit 字 (word 0-5)
        dev.reg_write(CORE, ADDR_TRIG_VALUE + i, 0)
        dev.reg_write(CORE, ADDR_TRIG_MASK + i, 0)
    dev.reg_write(CORE, ADDR_TRIG_VALUE + 0, 1)
    dev.reg_write(CORE, ADDR_TRIG_MASK + 0, 1)
    dev.reg_write(CORE, ADDR_PRETRIG, 512)
    dev.reg_write(CORE, ADDR_POSTTRIG, 1535)

    stop = threading.Event()
    def pinger():
        while not stop.is_set():
            subprocess.run(["ping", "-c", "1", "-W", "1", "-I", IFACE, TARGET],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.1)
    th = threading.Thread(target=pinger, daemon=True); th.start()
    time.sleep(0.3)

    dev.arm(CORE)
    print("ARMED, 等待触发...")
    done = False; st = 0
    for i in range(120):
        time.sleep(0.1)
        st = dev.get_status(CORE)
        if (st >> 2) & 1: done = True; break
    stop.set(); th.join(timeout=2)
    if not done:
        print("TIMEOUT - 强制触发...")
        dev.force_trig(CORE); time.sleep(0.5)
        st = dev.get_status(CORE); done = (st >> 2) & 1
    print(f"status={st:#x} done={done}")

    cfg = dev.get_core_cfg(CORE)
    samples = dev.read_all_samples(CORE, cfg)
    print(f"read {len(samples)} samples, width={cfg.total_width}")

    def sig(name):
        lo, w = P[name]; m = (1 << w) - 1
        return [(s >> lo) & m for s in samples]

    rx_dv = sig("gmii_rx_dv"); mac_rx_en = sig("mac_rx_en")
    mac_rx_sop = sig("mac_rx_sop"); mac_rx_eop = sig("mac_rx_eop")
    cpu_wr_wen = sig("cpu_wr_wen_ind"); cpu_wr_push = sig("cpu_wr_wpkt_push_ind")
    cpu_rd_empty = sig("cpu_rd_empty"); cpu_rd_ren = sig("cpu_rd_ren")
    cpu_rd_pop = sig("cpu_rd_rpkt_pop_ind")
    bus_req = sig("bus_req"); bus_rhwl = sig("bus_rhwl"); bus_addr = sig("bus_address")
    bus_ack = sig("bus_ack"); bus_wdata = sig("bus_wdata"); bus_rdata = sig("bus_rdata")
    tx_en = sig("gmii_tx_en"); mac_tx_en = sig("mac_tx_en"); led = sig("led_o")

    def cnt(x): return sum(x)
    def edges(x): return [i for i in range(1, len(x)) if x[i] and not x[i-1]]

    print("\n=== RX 数据通路诊断 (2048 样本 @ 50MHz = 40.96us) ===")
    print(f"[1] gmii_rx_dv   活动: {cnt(rx_dv)} 样本 ({cnt(rx_dv)*20}ns)  上升沿@{edges(rx_dv)[:5]}")
    print(f"[2] mac_rx_en    活动: {cnt(mac_rx_en)} 样本 ({cnt(mac_rx_en)*20}ns)")
    print(f"    mac_rx_sop   脉冲: {cnt(mac_rx_sop)}  mac_rx_eop: {cnt(mac_rx_eop)}")
    print(f"[3] cpu_wr_wen   脉冲: {cnt(cpu_wr_wen)}   (写 FIFO 使能)")
    print(f"    cpu_wr_push  脉冲: {cnt(cpu_wr_push)}   (整包推入 FIFO)")
    print(f"[4] cpu_rd_empty 低(=有数据)样本: {len(cpu_rd_empty)-cnt(cpu_rd_empty)}")
    print(f"    cpu_rd_ren   脉冲: {cnt(cpu_rd_ren)}   cpu_rd_pop: {cnt(cpu_rd_pop)}")

    print("\n=== CPU 总线活动 ===")
    print(f"bus_req: {cnt(bus_req)} 样本, bus_ack: {cnt(bus_ack)}")
    addrs = {}
    for i in range(len(samples)):
        if bus_req[i]:
            key = (bus_addr[i], bus_rhwl[i])
            addrs[key] = addrs.get(key, 0) + 1
    for (a, rw), c in sorted(addrs.items(), key=lambda x: -x[1])[:20]:
        print(f"  0x{a:08x} {'读' if rw else '写'}: {c}")

    print("\n=== TX 活动 (应非零才说明 CPU 在回 ARP) ===")
    print(f"gmii_tx_en: {cnt(tx_en)}  mac_tx_en: {cnt(mac_tx_en)}  led_o: {sorted(set(led))}")

    # 新增 6 探针 — 丢包根因判定
    rx_afifo_full = sig("rx_afifo_full_cnt"); rx_correct = sig("rx_correct_pkt_cnt")
    rx_crc_err = sig("rx_crc_err_pkt_cnt"); recv_drop = sig("recv_pkt_drop_cnt")
    mac_in_full = sig("mac_in_full"); gmii_rx_er = sig("gmii_rx_er")

    print("\n=== 丢包根因判定 (新增 6 探针) ===")
    print(f"rx_correct_pkt_cnt = {max(rx_correct):3d}  (>0=物理层正常, 好FCS帧计数)")
    print(f"rx_crc_err_pkt_cnt = {max(rx_crc_err):3d}  (>0=物理层损坏: IDELAY/位序/时钟)")
    print(f"rx_afifo_full_cnt = {max(rx_afifo_full):3d}  (>0=内部异步FIFO Eth_RXC→125m 溢出丢字节)")
    print(f"recv_pkt_drop_cnt = {max(recv_drop):3d}  (>0=125m→50m FIFO 满丢整包)")
    print(f"mac_in_full       = {max(mac_in_full)}      (1=full 卡高, CDC 指针问题)")
    print(f"gmii_rx_er 活动   = {cnt(gmii_rx_er)} 样本 (PHY 错误标志)")

    # cpu_rd_empty 时序: 找下降沿(有数据到来)
    rd_fall = [i for i in range(1, len(cpu_rd_empty)) if not cpu_rd_empty[i] and cpu_rd_empty[i-1]]
    print(f"\ncpu_rd_empty 下降沿(数据入队)@{rd_fall[:10]}")
    wr_edges = edges(cpu_wr_wen)
    print(f"cpu_wr_wen 上升沿@{wr_edges[:10]}")

    dev.t.close()
    return 0

if __name__ == "__main__":
    sys.exit(main())
