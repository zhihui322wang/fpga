#!/usr/bin/env python3
"""
ILA 发包/诊断工具 — 验证 FPGA ILA UART 通信

用法:
  python3 ila_sender.py ping          # 使用官方 Device API 发送 PING
  python3 ila_sender.py raw           # 原始字节发送+接收（逐字节对比）
  python3 ila_sender.py loopback      # 仅接收模式（不发送，观察 FPGA 自发数据）
  python3 ila_sender.py bench         # 发送多种 core_id 的 PING 帧
"""
import sys
import os
import time

# 添加 fpga_ila 库路径
sys.path.insert(0, "/home/zhihuiw/fpga_work/fpga_ila_local/host")

from fpga_ila import Device, SerialTransport, protocol as P
from fpga_ila.transport import SerialTransport

PORT = "/dev/ttyUSB1"
BAUD = 921600

def hexdump(data, prefix="  "):
    """格式化的十六进制 dump"""
    if not data:
        print(f"{prefix}(空)")
        return
    hex_str = " ".join(f"{b:02x}" for b in data)
    ascii_str = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
    print(f"{prefix}{hex_str}")
    print(f"{prefix}{'  '}{ascii_str}")


def cmd_ping():
    """使用官方 Device API 发送 PING"""
    print("=" * 60)
    print("PING 测试 — 使用官方 Device API")
    print(f"  端口: {PORT}, 波特率: {BAUD}")
    print("=" * 60)

    try:
        t = SerialTransport(PORT, BAUD)
        dev = Device(t)

        print("\n[1] 发送 PING 帧 (BCAST=0xFF)...")
        idcode = dev.ping()

        print(f"\n[2] 响应 IDCODE: {idcode:#010x}")
        if idcode == P.ILA_IDCODE:
            print(f"    ✓ 匹配! (ILA_IDCODE = {P.ILA_IDCODE:#010x} = '{P.ILA_IDCODE.to_bytes(4,'big').decode()}')")
        else:
            print(f"    ✗ 不匹配! 期望 {P.ILA_IDCODE:#010x}")

        dev.t.close()
        return 0

    except Exception as e:
        print(f"\n[错误] {e}")
        return 1


def cmd_raw():
    """原始字节发送+接收，用于诊断"""
    import serial

    print("=" * 60)
    print("原始字节诊断")
    print(f"  端口: {PORT}, 波特率: {BAUD}")
    print("=" * 60)

    # PING frame: 55 AA <core_id> <cmd> <len_lo> <len_hi> <crc_lo> <crc_hi>
    # Device.ping() sends core_id=0xFF (BCAST)
    frame_bcast = P.build_frame(P.BCAST, P.CMD_PING, b'')
    frame_core0 = P.build_frame(0, P.CMD_PING, b'')

    print(f"\n[1] 构建的帧 (BCAST=0xFF):")
    hexdump(frame_bcast)
    print(f"    长度: {len(frame_bcast)} bytes")

    ser = serial.Serial(PORT, BAUD, timeout=0.05)
    ser.reset_input_buffer()
    ser.reset_output_buffer()

    # 先读一次 — 清空缓冲区，同时看看有没有自发数据
    pending = ser.read(1024)
    if pending:
        print(f"\n[0] 清空缓冲区时读到的自发数据 ({len(pending)} bytes):")
        hexdump(pending)
    else:
        print(f"\n[0] 缓冲区空 (无自发数据)")

    # 发送
    print(f"\n[2] 发送 {len(frame_bcast)} bytes:")
    hexdump(frame_bcast)
    n_written = ser.write(frame_bcast)
    ser.flush()
    print(f"    实际写入: {n_written} bytes")

    # 等待响应
    time.sleep(0.01)  # 10ms — 8 bytes at 921600 baud ≈ 0.09ms, generous

    # 读取
    resp = ser.read(1024)
    print(f"\n[3] 响应 ({len(resp)} bytes):")
    hexdump(resp)

    # 分析
    if resp:
        print(f"\n[4] 逐字节分析:")
        for i, b in enumerate(resp):
            b_str = f"0x{b:02x}"
            ch = chr(b) if 32 <= b < 127 else "."
            note = ""
            if b == P.SYNC0:
                note = " ← SYNC0"
            elif b == P.SYNC1:
                note = " ← SYNC1"
            elif b == 0xFA:
                note = " ← 0xFA (EJTAG-UART 帧定界符?)"
            print(f"    [{i:2d}] {b_str} ({b:3d}) '{ch}'{note}")

        # 检查是否有 0xFA 模式
        fa_count = sum(1 for b in resp if b == 0xFA)
        print(f"\n    0xFA 出现次数: {fa_count}/{len(resp)}")

        # 检查是否能找到 FCAPZ 响应帧
        # 期望: 55 AA <cid> 81 <len_lo> <len_hi> <idcode[3:0]> <idcode[2:0]> <idcode[1:0]> <idcode[0:0]> <crc_lo> <crc_hi>
        resp_hex = resp.hex()
        # 找 55 AA 模式
        for j in range(len(resp) - 1):
            if resp[j] == P.SYNC0 and resp[j+1] == P.SYNC1:
                print(f"\n    找到 SYNC 序列 @ offset {j}")
                if j + 7 < len(resp):
                    cid, cmd = resp[j+2], resp[j+3]
                    print(f"      core_id={cid:#04x}, cmd={cmd:#04x}")
                    if cmd & P.CMD_RESP_FLAG:
                        print(f"      ← 响应帧! (CMD_RESP_FLAG set)")
                        len_lo, len_hi = resp[j+4], resp[j+5]
                        plen = len_lo | (len_hi << 8)
                        print(f"      payload 长度: {plen}")

        # 检查 0xFA 前后关系
        if fa_count > 0:
            print(f"\n    0xFA 字节位置:")
            for i, b in enumerate(resp):
                if b == 0xFA:
                    next_byte = resp[i+1] if i+1 < len(resp) else None
                    print(f"      offset {i}: FA {next_byte:#04x}" if next_byte else f"      offset {i}: FA (末尾)")

    ser.close()
    return 0


def cmd_loopback():
    """仅接收模式 — 看 FPGA 是否自发输出数据"""
    import serial

    print("=" * 60)
    print("监听模式 — 接收 FPGA 自发输出 (不发送任何数据)")
    print(f"  端口: {PORT}, 波特率: {BAUD}")
    print("  按 Ctrl+C 停止")
    print("=" * 60)

    ser = serial.Serial(PORT, BAUD, timeout=0.5)
    ser.reset_input_buffer()

    count = 0
    try:
        while count < 20:
            data = ser.read(1024)
            if data:
                print(f"\n[{count}] 收到 {len(data)} bytes:")
                hexdump(data)
                count += 1
            else:
                sys.stdout.write(".")
                sys.stdout.flush()
    except KeyboardInterrupt:
        print("\n\n停止")
    finally:
        ser.close()
    return 0


def cmd_bench():
    """发送多种 PING 帧测试"""
    import serial

    print("=" * 60)
    print("多发测试 — 尝试多种 core_id 的 PING")
    print(f"  端口: {PORT}, 波特率: {BAUD}")
    print("=" * 60)

    ser = serial.Serial(PORT, BAUD, timeout=0.05)

    # 测试不同 core_id
    core_ids = [0x00, 0xFF]
    for cid in core_ids:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        frame = P.build_frame(cid, P.CMD_PING, b'')
        print(f"\n--- core_id={cid:#04x} ---")
        print(f"发送: {frame.hex()}")
        ser.write(frame)
        ser.flush()
        time.sleep(0.01)
        resp = ser.read(256)
        if resp:
            print(f"响应: {resp.hex()} ({len(resp)} bytes)")
            fa = sum(1 for b in resp if b == 0xFA)
            if fa:
                print(f"  ⚠ 0xFA 出现 {fa} 次")
            # 尝试查找 55 AA 响应
            for j in range(len(resp)-1):
                if resp[j] == 0x55 and resp[j+1] == 0xAA:
                    print(f"  → 找到 SYNC @ {j}")
                    remaining = resp[j:]
                    print(f"    尾部: {remaining.hex()}")
                    if len(remaining) >= 8:
                        cmd = remaining[3]
                        if cmd & 0x80:
                            print(f"    ← FCAPZ 响应帧! cmd={cmd:#04x}")
        else:
            print("响应: (无)")

    ser.close()
    return 0


if __name__ == "__main__":
    cmds = {
        "ping":     cmd_ping,
        "raw":      cmd_raw,
        "loopback": cmd_loopback,
        "bench":    cmd_bench,
    }
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        print(f"用法: {sys.argv[0]} <command>")
        print(f"命令: {', '.join(cmds)}")
        sys.exit(1)
    sys.exit(cmds[sys.argv[1]]())
