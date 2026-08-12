#!/usr/bin/env python3
"""
ILA 触发配置 + 采集脚本 — gmii_rx_dv 触发
用法:
  1. 先关闭 ILA GUI (释放串口 /dev/ttyACM0)
  2. python3 ila_capture.py        # 配置触发 + arm + 等待
  3. 另一终端: ping 169.254.1.1   # 产生 GMII 流量触发
  4. 重开 GUI: ./ila_gui.sh       # 查看波形
"""
import sys
import time
sys.path.insert(0, "/home/zhihuiw/fpga_work/fpga_ila_local/host")
from fpga_ila import Device, SerialTransport, protocol as P

PORT = "/dev/ttyACM0"
BAUD = 921600
CORE = 0

# 寄存器地址 (from ila_pkg.vh)
ADDR_TRIG_VALUE  = 0x0024   # 触发值 (多字, base)
ADDR_TRIG_MASK   = 0x0028   # 触发掩码 (多字, base)
ADDR_PRETRIG     = 0x0014   # 触发前样本数
ADDR_POSTTRIG    = 0x0018   # 触发后样本数
ADDR_TRIG_MODE   = 0x0020   # 触发模式: bit0=value_match, bit1=edge
ADDR_CTRL        = 0x0004   # 控制: bit0=arm_toggle
ADDR_STATUS      = 0x0008   # 状态: bit0=armed, bit1=triggered, bit2=done

# gmii_rx_dv = probe 0, bit_lo=0, width=1 → 在 word0 bit0
# 150bit 总线 = 5 个 32-bit 字 (word 0-4)

def main():
    print("=" * 60)
    print("ILA 触发配置 — gmii_rx_dv 上升沿触发")
    print(f"  端口: {PORT}, 波特率: {BAUD}")
    print("=" * 60)

    t = SerialTransport(PORT, BAUD)
    dev = Device(t)

    # ====== Step 1: PING ======
    print("\n[Step 1] PING ILA Hub...")
    try:
        idcode = dev.ping()
        print(f"  ✓ PING OK — IDCODE: {idcode:#010x} ('{idcode.to_bytes(4,'big').decode()}')")
    except Exception as e:
        print(f"  ✗ PING FAILED: {e}")
        return 1

    # ====== Step 2: 配置触发 ======
    print("\n[Step 2] 配置触发 — gmii_rx_dv = 1")

    # 触发模式: 值匹配
    print("  TRIG_MODE = 1 (value match)")
    dev.reg_write(CORE, ADDR_TRIG_MODE, 0x00000001)

    # 清空所有 TRIG_VALUE 和 TRIG_MASK word
    for word_idx in range(5):
        dev.reg_write(CORE, ADDR_TRIG_VALUE + word_idx, 0x00000000)
        dev.reg_write(CORE, ADDR_TRIG_MASK  + word_idx, 0x00000000)

    # TRIG_VALUE word 0: bit 0 = 1 (gmii_rx_dv = 高)
    print("  TRIG_VALUE[0] = 0x00000001 (gmii_rx_dv = 1)")
    dev.reg_write(CORE, ADDR_TRIG_VALUE + 0, 0x00000001)

    # TRIG_MASK word 0: bit 0 = 1 (只监测 bit0)
    print("  TRIG_MASK[0]  = 0x00000001 (只比较 bit0)")
    dev.reg_write(CORE, ADDR_TRIG_MASK + 0, 0x00000001)

    # ====== Step 3: 采集窗口 ======
    PRETRIG  = 512
    POSTTRIG = 1535   # 512 + 1535 + 1 = 2048 (depth limit)

    print(f"\n[Step 3] 采集窗口 — PRETRIG={PRETRIG}, POSTTRIG={POSTTRIG}")
    dev.reg_write(CORE, ADDR_PRETRIG,  PRETRIG)
    dev.reg_write(CORE, ADDR_POSTTRIG, POSTTRIG)

    # 验证
    pt_read = dev.reg_read(CORE, ADDR_PRETRIG)
    po_read = dev.reg_read(CORE, ADDR_POSTTRIG)
    print(f"  读回: PRETRIG={pt_read}, POSTTRIG={po_read}")

    # ====== Step 4: ARM ======
    print(f"\n[Step 4] ARM — 等待触发...")
    dev.arm(CORE)

    # 确认已 ARM
    time.sleep(0.1)
    status = dev.get_status(CORE)
    armed   = (status >> 0) & 1
    triggered = (status >> 1) & 1
    done    = (status >> 2) & 1
    print(f"  状态: armed={armed} triggered={triggered} done={done}")

    # ====== Step 5: 等待触发 ======
    print(f"\n[Step 5] 请在另一终端运行: ping 169.254.1.1")
    print(f"  等待触发中 (timeout=10s)...")

    for i in range(100):
        time.sleep(0.1)
        status = dev.get_status(CORE)
        done = (status >> 2) & 1
        triggered = (status >> 1) & 1
        if done:
            print(f"\n  ✓ 采集完成! (status={status:#010x})")
            break
        if i % 20 == 19:
            print(f"  等待中... ({i*0.1:.0f}s)")

    if not done:
        print(f"\n  ⚠ Timeout — 未检测到触发")
        print(f"  最终状态: {status:#010x}")
        # 尝试 force trigger
        print(f"  尝试 FORCE_TRIG...")
        dev.force_trig(CORE)
        time.sleep(0.5)
        status = dev.get_status(CORE)
        done = (status >> 2) & 1
        print(f"  状态: done={done}")

    # ====== 结果 ======
    if done:
        print(f"\n{'='*60}")
        print(f"✓ 采集完成! 数据已保存在 FPGA BRAM 中")
        print(f"  现在关闭此脚本, 重开 ILA GUI 查看波形:")
        print(f"  ./ila_gui.sh")
        print(f"{'='*60}")

    dev.t.close()
    return 0

if __name__ == "__main__":
    sys.exit(main())
