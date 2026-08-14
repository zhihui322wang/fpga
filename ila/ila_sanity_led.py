#!/usr/bin/env python3
"""
ILA sanity check — 触发 led_o (CPU 心跳, 1→2→4→8 循环, 每态50ms)
led[0]=1 每 200ms 出现 50ms。若 2 秒内还触发不了, 说明 ILA/烧录本身有问题。
"""
import sys, time
sys.path.insert(0, "/home/zhihuiw/fpga_work/fpga_ila_local/host")
from fpga_ila import Device, SerialTransport, protocol as P

PORT = "/dev/ttyACM0"; BAUD = 921600; CORE = 0
ADDR_TRIG_MODE=0x0020; ADDR_TRIG_VALUE=0x0024; ADDR_TRIG_MASK=0x0028
ADDR_PRETRIG=0x0014; ADDR_POSTTRIG=0x0018

PROBE_WIDTHS = [1,8,1,8, 1,1,8,1, 1,1,8,1, 1,1,1,32, 32,1,32,1, 1,1,1, 1,1,4,8, 8,8,8, 1,1]
def bit_lo(idx): return sum(PROBE_WIDTHS[:idx])

def main():
    t = SerialTransport(PORT, BAUD); dev = Device(t)
    try:
        idc = dev.ping(); print(f"[1] PING OK idcode={idc:#x}")
    except Exception as e:
        print(f"[1] PING FAILED: {e}"); return 1

    # 触发 led[0] (probe25 bit0, 全局位146)
    bi = bit_lo(25); w = bi//32; b = bi%32
    dev.reg_write(CORE, ADDR_TRIG_MODE, 0x01)
    for k in range(6):
        dev.reg_write(CORE, ADDR_TRIG_VALUE+k, 0); dev.reg_write(CORE, ADDR_TRIG_MASK+k, 0)
    dev.reg_write(CORE, ADDR_TRIG_VALUE+w, 1<<b); dev.reg_write(CORE, ADDR_TRIG_MASK+w, 1<<b)
    print(f"[2] 触发 led[0]: 全局位{bi} (word{w} bit{b})")

    dev.reg_write(CORE, ADDR_PRETRIG, 64); dev.reg_write(CORE, ADDR_POSTTRIG, 1983)
    dev.arm(CORE); time.sleep(0.1)
    print("[3] ARM 完成, 等 led 心跳 (1→2→4→8, 每态50ms, led[0]=1 每200ms出现)...")

    done=False; st=0
    for i in range(200):  # 20s
        time.sleep(0.1); st=dev.get_status(CORE); done=(st>>2)&1
        if done: break
    if not done:
        print(f"[4] 超时未触发 status={st:#x} (armed={st&1} trig={(st>>1)&1}) → ILA/烧录本身有问题!"); dev.t.close(); return 0
    print(f"[4] 已触发 status={st:#x} → ILA 工作正常")

    # 读回 led 附近样本验证
    cfg = dev.get_core_cfg(CORE)
    raw = bytearray(); chunk = max(1, 512 // cfg.bytes_per_sample); a=0
    while a < cfg.data_depth:
        n=min(chunk, cfg.data_depth-a); raw += dev.read_buf(CORE,a,n); a+=n
    from fpga_ila.capture import decode_samples
    samples = decode_samples(bytes(raw), cfg.total_width)
    bl = bit_lo(25)
    led = [(s>>bl)&0xF for s in samples]
    # 统计 led 值分布
    from collections import Counter
    print("[5] led 值分布 (前64后64跳过pretrig):")
    print("    ", Counter(led).most_common(8))
    dev.t.close(); return 0

if __name__ == "__main__":
    sys.exit(main())
