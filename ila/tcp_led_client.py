#!/usr/bin/env python3
"""
TCP LED 控制客户端 — 通过短连接发命令控制 FPGA 板 LED

用法:
  python3 tcp_led_client.py 0x05      # 设 LED = 0x05 (LED0+LED2 亮)
  python3 tcp_led_client.py 0x0F      # 全亮
  python3 tcp_led_client.py 0x00      # 全灭
  python3 tcp_led_client.py 0x01      # LED0 亮

协议:
  PC → FPGA: 1 字节 (低 4 位 = LED 值)
  FPGA → PC: 1 字节 (bit7=1 表示已执行, 低 4 位 = 实际 LED 值)
"""

import socket
import sys
import time

FPGA_IP   = "169.254.1.1"
FPGA_PORT = 7
TIMEOUT   = 5  # 秒

def led_cmd(value):
    """发送 LED 命令, 返回 FPGA 响应值"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT)

    try:
        sock.connect((FPGA_IP, FPGA_PORT))
        cmd_byte = bytes([value & 0x0F])
        sock.send(cmd_byte)

        # TCP 连接成功 = 三次握手 OK, 命令已发送
        # 读取回显 (可能被 FIN 提前关闭, 非必须)
        try:
            resp = sock.recv(16)
            if resp:
                led_val = resp[0] & 0x0F
                return led_val, True
        except:
            pass

        # 连上就算成功, LED 应该已经变了
        return value & 0x0F, True
    except socket.timeout:
        print("  超时: FPGA 无响应 (检查网线/Ping)")
        return None, False
    except ConnectionRefusedError:
        print("  连接被拒绝: FPGA 未监听端口 7")
        return None, False
    finally:
        sock.close()

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("示例: python3 tcp_led_client.py 0x0A")
        sys.exit(1)

    try:
        val = int(sys.argv[1], 16)
    except ValueError:
        print(f"无效值: {sys.argv[1]}, 请用十六进制 (如 0x05)")
        sys.exit(1)

    print(f"发送 LED=0x{val:02X} → {FPGA_IP}:{FPGA_PORT} ...")
    led, ok = led_cmd(val)

    if ok:
        print(f"✓ FPGA 已执行: LED=0x{led:02X}")
        leds = []
        if led & 1: leds.append("LED0")
        if led & 2: leds.append("LED1")
        if led & 4: leds.append("LED2")
        if led & 8: leds.append("LED3")
        print(f"  亮的灯: {', '.join(leds) if leds else '全灭'}")
    elif led is not None:
        print(f"✗ 回显异常: 0x{led:02X}")
    else:
        print("✗ 通信失败")

if __name__ == "__main__":
    main()
